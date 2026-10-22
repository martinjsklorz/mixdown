extension TranscriptionError {
    /// `error` from preparing a model as a `TranscriptionError`: unchanged if it already is one,
    /// else `modelUnavailable` with its description.
    public static func unavailable(_ error: any Error) -> TranscriptionError {
        if let error = error as? TranscriptionError { return error }
        return .modelUnavailable(error.localizedDescription)
    }
}
