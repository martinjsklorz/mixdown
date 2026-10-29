extension TranscriptionError {
    /// `error` from preparing a model as a `TranscriptionError`: unchanged if it already is one,
    /// else `modelUnavailable` with its description.
    public static func unavailable(_ error: any Error) -> TranscriptionError {
        if let error = error as? TranscriptionError { return error }
        return .modelUnavailable(error.localizedDescription)
    }

    /// `error` from preparing a model, to rethrow: `CancellationError` if it is one or the task
    /// was cancelled, else `unavailable(error)`.
    public static func unavailableOrCancelled(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        return unavailable(error)
    }

    /// `error` from running a model, to rethrow: `CancellationError` if it is one or the task was
    /// cancelled, unchanged if it's a `TranscriptionError`, else `failed` with its description.
    public static func failure(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? TranscriptionError { return error }
        return TranscriptionError.failed(error.localizedDescription)
    }
}
