import Foundation

enum Config {
    /// Resolves for anyone; routes for nobody off the tailnet. A failure to
    /// reach it is therefore "Tailscale is off", not "the hub is down" - which
    /// is why HubError separates .unreachable from .unauthorized.
    ///
    /// SAME HUB AS RACK CONTROL. If this ever needs to differ, the two apps
    /// stop sharing a token as well, because the token is that hub's secret.
    static let baseURL = URL(string: "https://example.com")!
}
