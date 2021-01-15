import Foundation
#if SWIFT_PACKAGE
@_implementationOnly import Fishhook
import Orion
#endif

extension Backends {

    /// A backend which uses Fishhook to hook functions.
    ///
    /// Other hook requests are forwarded to the `UnderlyingBackend`.
    /// This backend conditionally conforms to `DefaultBackend` iff
    /// `UnderlyingBackend` does as well.
    ///
    /// - Warning: This backend does not support hooking functions by
    /// their address. It is also subject to the pitfalls of Fishhook,
    /// for example calls to hooked functions from within the image in
    /// which the function is declared may still use the original
    /// implementation. In addition, all instances of symbols with
    /// the same name as the target function are hooked, not just the
    /// one in the requested image.
    public struct Fishhook<UnderlyingBackend: Backend>: Backend {
        let underlyingBackend: UnderlyingBackend

        /// Initializes the Fishhook backend with the provided underlying
        /// backend.
        ///
        /// - Parameter underlyingBackend: The backend to fall back to
        /// for non-function hooking.
        public init(underlyingBackend: UnderlyingBackend) {
            self.underlyingBackend = underlyingBackend
        }
    }

}

extension Backends.Fishhook {

    private struct Request {
        let symbol: String
        let replacement: UnsafeMutableRawPointer
        let image: URL?
        let completion: (UnsafeMutableRawPointer) -> Void
    }

    private func apply(functionHookRequests requests: [Request]) {
        guard !requests.isEmpty else { return }

        // we need to keep this around, so we don't deallocate it. See comment in rebinding.init call
        // for rationale.
        let origs = UnsafeMutableBufferPointer<UnsafeMutableRawPointer?>.allocate(capacity: requests.count)
        var rebindings: [rebinding] = []
        var completions: [(UnsafeMutableRawPointer?) -> Void] = []

        requests.enumerated().forEach { idx, request in
            // NOTE: We don't use the orig that fishhook returns because calling that seems to rebind
            // the dyld symbol stub, which means our hook only works up until it decides to call orig
            // after which all future calls are broken.
            // See: https://github.com/facebook/fishhook/issues/36

            // this is only used on error code-paths so it's a computed var
            var function: Function { .symbol(request.symbol, image: request.image) }

            let handle: UnsafeMutableRawPointer
            if let image = request.image {
                guard let _handle = image.withUnsafeFileSystemRepresentation({ dlopen($0, RTLD_NOLOAD | RTLD_NOW) })
                    else { orionError("Image not loaded: \(image.path)") }
                handle = _handle
            } else {
                handle = UnsafeMutableRawPointer(bitPattern: -2)! // RTLD_DEFAULT
            }

            guard let orig = dlsym(handle, request.symbol) else {
                orionError("Could not find function \(function)")
            }

            rebindings.append(rebinding(
                // Turns out fishhook doesn't copy this string so we're responsible for keeping
                // it alive, because the rebindings are stored globally, and are accessed not
                // only when rebind_symbols is called but also every time a new image is added.
                // While we could use a dict to keep a single copy of each symbol alive, blindly
                // calling strdup is alright since each hooked symbol is most likely unique anyway.
                name: strdup(request.symbol),
                replacement: request.replacement,
                // this is also stored globally, as mentioned above. It appears that fishhook writes
                // to this each time an image is processed, passing in that image's orig stub. Even
                // though this orig is later discarded, we can't pass NULL because we do check it in
                // order to know whether hooking was successful
                replaced: origs.baseAddress! + idx
            ))

            completions.append { brokenOrig in
                guard brokenOrig != nil else {
                    orionError("Failed to hook function \(function)")
                }
                request.completion(orig)
            }
        }

        guard orion_rebind_symbols(&rebindings, rebindings.count) == 0
            else { orionError("Failed to hook functions") }

        zip(completions, origs).forEach { $0($1) }
    }

    public func apply(hooks: [HookDescriptor]) {
        var requests: [Request] = []
        var forwardedHooks: [HookDescriptor] = []

        hooks.forEach {
            switch $0 {
            case .function(.address, _, _):
                orionError("""
                The fishhook backend cannot hook functions at raw addresses. If possible, provide \
                a symbol name and image instead.
                """)
            case let .function(.symbol(symbol, image: image), replacement, completion):
                requests.append(
                    Request(
                        symbol: symbol,
                        replacement: replacement,
                        image: image,
                        completion: completion
                    )
                )
            default:
                forwardedHooks.append($0)
            }
        }

        underlyingBackend.apply(hooks: forwardedHooks)
        apply(functionHookRequests: requests)
    }

}

extension Backends.Fishhook: DefaultBackend where UnderlyingBackend: DefaultBackend {
    public init() {
        self.init(underlyingBackend: UnderlyingBackend())
    }
}
