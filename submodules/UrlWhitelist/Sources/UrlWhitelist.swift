import Foundation

// ice9: only our hosts open a concealed link without showing it first (#87)
private let whitelistedHosts: Set<String> = Set([
    "i.ice9.app",
    "ice9.app"
])

public func isConcealedUrlWhitelisted(_ url: URL) -> Bool {
    if var host = url.host?.lowercased() {
        let www = "www."
        if host.hasPrefix(www) {
            host.removeFirst(www.count)
        }
        if whitelistedHosts.contains(host) {
            return true
        }
    }
    // ice9: no /blog/ and /tour/ exceptions; the host is whitelisted whole (#102)
    return false
}

public func parseUrl(url: String, wasConcealed: Bool) -> (string: String, concealed: Bool) {
    var parsedUrlValue: URL?
    if url.hasPrefix("tel:") {
        return (url, false)
    } else if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://"), let parsed = URL(string: url) {
        parsedUrlValue = parsed
    } else if let parsed = URL(string: "https://" + url) {
        parsedUrlValue = parsed
    } else if let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let parsed = URL(string: encoded) {
        parsedUrlValue = parsed
    }
    let host = parsedUrlValue?.host ?? url
    
    let rawHost = (host as NSString).removingPercentEncoding ?? host
    var latin = CharacterSet()
    latin.insert(charactersIn: "A"..."Z")
    latin.insert(charactersIn: "a"..."z")
    latin.insert(charactersIn: "0"..."9")
    var punctuation = CharacterSet()
    punctuation.insert(charactersIn: ".-/+_?=")
    var hasLatin = false
    var hasNonLatin = false
    for c in rawHost {
        if c.unicodeScalars.allSatisfy(punctuation.contains) {
        } else if c.unicodeScalars.allSatisfy(latin.contains) {
            hasLatin = true
        } else {
            hasNonLatin = true
        }
    }
    var concealed = wasConcealed
    if hasLatin && hasNonLatin {
        concealed = true
    }
    
    var rawDisplayUrl: String
    if hasNonLatin {
        rawDisplayUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    } else {
        rawDisplayUrl = url
    }
    
    if let parsedUrlValue = parsedUrlValue, isConcealedUrlWhitelisted(parsedUrlValue) {
        concealed = false
    }
    
    let whitelistedSchemes: [String] = [
        "tel",
    ]
    if let parsedUrlValue = parsedUrlValue, let scheme = parsedUrlValue.scheme, whitelistedSchemes.contains(scheme) {
        concealed = false
    }
    
    if url.hasPrefix("tg2://premium_multigift") || url.hasPrefix("tg2://premium_offer") {
        concealed = false
    }
    
    return (rawDisplayUrl, concealed)
}
