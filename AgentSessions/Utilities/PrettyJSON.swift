import Foundation

enum PrettyJSON {
    static func prettyPrinted(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return json }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            return ToolJSON.string(from: obj, pretty: true) ?? json
        } catch {
            return json
        }
    }
}
