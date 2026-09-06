import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VeloxQuantClient {
    /// Inspects the response body before deciding the error type — never dispatches on status
    /// code alone (investigation §1.8/§1.2).
    ///
    /// - A 404 whose body parses as `{"error": "..."}` JSON → `.generationFailed` (`mlx_lm`'s
    ///   server returns 404 for generation errors, not wrong routes).
    /// - A 404 whose body is the literal plain-text `Not Found` → `.unexpectedRoute`.
    /// - Neither → `.malformedErrorResponse` (also covers the confirmed finding that
    ///   `validate_model_parameters`'s `ValueError` is uncaught upstream, so a bad request can
    ///   come back as a broken/partial response rather than a clean JSON error body).
    /// - Non-404, non-2xx with a parseable `{"error": ...}` body → `.serverError`.
    func validateResponse(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VeloxQuantError.malformedErrorResponse(statusCode: -1, rawBody: "")
        }
        guard http.statusCode != 200, http.statusCode != 204 else { return }

        let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"

        if http.statusCode == 404 {
            if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw VeloxQuantError.generationFailed(serverMessage: errorBody.error)
            }
            if rawBody == "Not Found" {
                throw VeloxQuantError.unexpectedRoute(path: http.url?.path ?? "<unknown>")
            }
            throw VeloxQuantError.malformedErrorResponse(statusCode: 404, rawBody: rawBody)
        }

        if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            throw VeloxQuantError.serverError(statusCode: http.statusCode, message: errorBody.error)
        }
        throw VeloxQuantError.malformedErrorResponse(statusCode: http.statusCode, rawBody: rawBody)
    }

    /// Same dispatch logic as `validateResponse(_:_:)`, applied to a streaming response before
    /// any bytes are consumed — a non-2xx streaming response never has a body worth decoding as
    /// SSE frames.
    func validateStreamingResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VeloxQuantError.malformedErrorResponse(statusCode: -1, rawBody: "")
        }
        guard http.statusCode != 200 else { return }

        if http.statusCode == 404 {
            throw VeloxQuantError.unexpectedRoute(path: http.url?.path ?? "<unknown>")
        }
        throw VeloxQuantError.malformedErrorResponse(statusCode: http.statusCode, rawBody: "")
    }

    /// Maps a thrown error from `chat()`/`chatStream()`'s underlying network/decode calls into
    /// a `VeloxQuantError`. Errors already typed as `VeloxQuantError` pass through unchanged.
    func mapToVeloxQuantError(_ error: Error) -> VeloxQuantError {
        if let veloxQuantError = error as? VeloxQuantError {
            return veloxQuantError
        }
        if (error as? URLError) != nil {
            return .runtimeUnreachable(baseURL: baseURL, underlying: error)
        }
        return .malformedErrorResponse(statusCode: -1, rawBody: error.localizedDescription)
    }
}
