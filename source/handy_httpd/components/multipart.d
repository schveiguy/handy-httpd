/**
 * Defines data structures and parsing methods for dealing with multipart
 * encoded request bodies.
 */
module handy_httpd.components.multipart;

import handy_httpd.components.handler : HttpStatusException;
import handy_httpd.components.response : HttpStatus;
import handy_httpd.components.request;
import slf4d;
import streams;

/**
 * A single element that's part of a multipart/form-data body.
 */
struct MultipartElement {
    import std.typecons : Nullable;

    /**
     * The name of this element, as declared by this part's Content-Disposition
     * header `name` property. There is no guarantee that this name is unique
     * among all elements.
     */
    string name;

    /**
     * The filename of this element, as declared by this part's
     * Content-Disposition header `filename` property. Note that this may be
     * null if no filename exists.
     */
    Nullable!string filename;

    /**
     * The headers that were present with this element.
     */
    string[string] headers;

    /**
     * The body content of this element.
     */
    string content;
}

/**
 * A multipart/form-data body containing multiple elements, and some helper
 * methods for those elements.
 */
struct MultipartFormData {
    MultipartElement[] elements;

    /**
     * Determines if this form-data has an element with the given name. This
     * is case-sensitive. Note that there may be more than one element with a
     * given name.
     * Params:
     *   elementName = The name of the element to search for.
     * Returns: True if this form-data has such an element.
     */
    bool has(string elementName) const {
        foreach (element; elements) {
            if (element.name == elementName) return true;
        }
        return false;
    }
}

/**
 * An exception that's thrown if parsing multipart/form-data fails due to
 * invalid formatting or unexpected characters. This is a sub-class of the
 * `HttpStatusException`, with each multipart exception being a BAD_REQUEST.
 */
class MultipartFormatException : HttpStatusException {
    public this(string message) {
        super(HttpStatus.BAD_REQUEST, message);
    }
}

/**
 * The maximum number of parts to read in a multipart/form-data body. This is
 * declared as a safety measure to avoid infinite reading of malicious or
 * corrupted payloads.
 */
const MAX_ELEMENTS = 1024;

/**
 * Reads a request's body as multipart/form-data encoded elements.
 * Params:
 *   request = The request to read from.
 *   allowInfiniteRead = Whether to read until no more data is available.
 * Returns: The multipart/form-data that was read.
 */
MultipartFormData readBodyAsMultipartFormData(ref HttpRequest request, bool allowInfiniteRead = false) {
    import std.algorithm : startsWith;
    string contentType = request.headers.getFirst("Content-Type").orElse(null);
    if (contentType is null || !startsWith(contentType, "multipart/form-data")) {
        throw new MultipartFormatException("Content-Type is not multipart/form-data.");
    }
    long boundaryIdx = indexOf(contentType, "boundary=");
    if (boundaryIdx < 0) {
        throw new MultipartFormatException("Missing multipart boundary definition.");
    }
    string boundary = contentType[boundaryIdx + "boundary=".length .. $];
    debugF!"Reading multipart/form-data request body with boundary=%s"(boundary);
    string content = request.readBodyAsString(allowInfiniteRead);
    return parseMultipartFormData(content, boundary);
}

/**
 * A simple linear parser for multipart/form-data encoded content. Reads a
 * series of elements separated by a given boundary. An exception is thrown
 * if the given content doesn't conform to standard multipart format.
 *
 * The main purpose of this function is to parse the multipart boundaries and
 * hand-off parsing of each element to `readElement`.
 * Params:
 *   content = The content to parse.
 *   boundary = The boundary between parts. This is usually present in an HTTP
 *              request's Content-Type header.
 * Returns: The multipart/form-data content that's been parsed.
 */
MultipartFormData parseMultipartFormData(string content, string boundary) {
    import std.array : RefAppender, appender;
    const string boundaryNormal = "--" ~ boundary ~ "\r\n";
    const string boundaryEnd = "--" ~ boundary ~ "--";
    long nextIdx = 0; // The index in `content` to start reading from each iteration.
    ushort elementCount = 0; // The number of elements we've read so far.
    MultipartFormData data; // The multipart data that's been accumulated.
    RefAppender!(MultipartElement[]) partAppender = appender(&data.elements);
    while (elementCount < MAX_ELEMENTS) {
        // Check that we have enough data to read a boundary marker.
        if (content.length < nextIdx + boundary.length + 4) {
            throw new MultipartFormatException(
                "Unable to read next boundary marker: " ~
                content[nextIdx .. $] ~
                ". Expected " ~ boundary
            );
        }
        string nextBoundary = content[nextIdx .. nextIdx + boundary.length + 4];
        if (nextBoundary == boundaryEnd) {
            break; // We just read an ending boundary marker, so we're done here.
        } else if (nextBoundary == boundaryNormal) {
            // Find the end index of this element.
            const ulong elementStartIdx = nextIdx + boundary.length + 4;
            const ulong elementEndIdx = indexOf(content, "--" ~ boundary, elementStartIdx);
            traceF!"Reading element from body at [%d, %d)"(elementStartIdx, elementEndIdx);
            partAppender ~= readElement(content[elementStartIdx .. elementEndIdx]);
            nextIdx = elementEndIdx;
            elementCount++;
        } else {
            throw new MultipartFormatException("Invalid boundary: " ~ nextBoundary);
        }
    }
    return data;
}

/**
 * Reads a single multipart element. An exception is thrown if the given
 * content doesn't represent a valid multipart/form-data element.
 * Params:
 *   content = The raw content of the element, including headers and body.
 * Returns: The element that was read.
 */
private MultipartElement readElement(string content) {
    MultipartElement element;
    ulong bodyIdx = parseElementHeaders(element, content);
    parseContentDisposition(element);
    element.content = content[bodyIdx .. $ - 2]; // Ignore the trailing \r\n at the end of the body.
    return element;
}

/**
 * Parses the headers for a multipart element.
 * Params:
 *   element = A reference to the element that's being parsed.
 *   content = The content to parse.
 * Returns: The index at which the header ends, and the body starts.
 */
private ulong parseElementHeaders(ref MultipartElement element, string content) {
    import std.string : strip;
    ulong nextHeaderIdx = 0;
    ulong bodyIdx = content.length;
    bool parsingHeaders = true;
    while (parsingHeaders) {
        string headerContent;
        const long headerEndIdx = indexOf(content, "\r\n", nextHeaderIdx);
        if (headerEndIdx < 0) {
            // We couldn't find the end of the next header line, so assume that there's no body and this is the last header.
            debug_("Couldn't find end of header line. Assuming that this is the last header.");
            headerContent = content[nextHeaderIdx .. $];
            parsingHeaders = false;
        } else {
            // We found the end of the next header line.
            headerContent = content[nextHeaderIdx .. headerEndIdx];
            nextHeaderIdx = headerEndIdx + 2;
            // Check to see if this is the last header (expect one more \r\n after the normal ending).
            if (content.length >= nextHeaderIdx + 2 && content[nextHeaderIdx .. nextHeaderIdx + 2] == "\r\n") {
                bodyIdx = nextHeaderIdx + 2;
                parsingHeaders = false;
            }
        }
        const long headerValueSeparatorIdx = indexOf(headerContent, ":");
        if (headerValueSeparatorIdx < 0) {
            throw new MultipartFormatException("Invalid header line: " ~ headerContent);
        }
        // const ulong headerValueSeparatorIdx = countUntil(headerContent, ":");
        string headerName = strip(headerContent[0 .. headerValueSeparatorIdx]);
        string headerValue = strip(headerContent[headerValueSeparatorIdx + 1 .. $]);
        traceF!"Read multipart element header: %s=%s"(headerName, headerValue);
        element.headers[headerName] = headerValue;
    }
    return bodyIdx;
}

/**
 * Parses and populates multipart element metadata according to information
 * found in the element's Content-Disposition header.
 * Params:
 *   element = A reference to the element that's being parsed.
 */
private void parseContentDisposition(ref MultipartElement element) {
    import std.algorithm : startsWith, endsWith;
    import std.string : split, strip;
    import std.uri : decodeComponent;
    if ("Content-Disposition" !in element.headers) {
        throw new MultipartFormatException("Missing required Content-Disposition header for multipart element.");
    }
    string contentDisposition = element.headers["Content-Disposition"];
    string[] cdParts = split(contentDisposition, ";");
    foreach (string part; cdParts) {
        string stripped = strip(part);
        if (startsWith(stripped, "name=\"") && endsWith(stripped, "\"")) {
            element.name = decodeComponent(stripped[6 .. $ - 1]);
            traceF!"Element name: %s"(element.name);
        } else if (startsWith(stripped, "filename=\"") && endsWith(stripped, "\"")) {
            import std.typecons : nullable;
            element.filename = nullable(decodeComponent(stripped[10 .. $ - 1]));
            traceF!"Element filename: %s"(element.filename);
        }
    }
}

private long indexOf(T)(T[] array, T[] subset, ulong offset = 0) {
    if (subset.length > array.length) return -1;
    if (subset.length == array.length) {
        if (offset != 0) return -1;
        return subset == array ? 0 : -1;
    }
    if (subset.length == 0) return 0;
    long index = offset;
    while (index < (array.length - subset.length)) {
        if (array[index .. index + subset.length] == subset) return index;
        index++;
    }
    return -1;
}

unittest {
    assert(indexOf("abc", "a") == 0);
    assert(indexOf("abc", "a", 1) == -1);
    assert(indexOf("hello world!", "world") == 6);
    assert(indexOf("hello world!", "world", 7) == -1);
    assert(indexOf("hello world!", "world", 3) == 6);
    assert(indexOf("", "bleh") == -1);
    assert(indexOf("", "blerg", 42) == -1);
}
