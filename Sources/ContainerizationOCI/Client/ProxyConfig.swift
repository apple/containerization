import Foundation
import AsyncHTTPClient

public struct ProxyConfig {
    public static func(for url: URL?) -> HTTPClient.Configuration.Proxy? {
        let env = ProcessInfo.processInfo.environment
        let proxyEnv = env["HTTPS_PROXY"] ?? env["HTTP_PROXY"]
        guard let proxyEnv else {
            return nil
        }
        guard let url.host != env["NO_PROXY"] else {
            return nil
        }
        guard let proxyURL = URL(string: proxyEnv), let host = proxyURL.host(), let port = proxyURL.port else {
            return nil
        }
        return HTTPClient.Configuration.Proxy.server(host: host, port: port)
    }
}