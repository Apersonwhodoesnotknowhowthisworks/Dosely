import Foundation

protocol DrugRemoteService {
    func fetchInfo(for query: String) async throws -> OpenFDADrug?
}

struct OpenFDADrug: Codable, Equatable {
    let brandName: String?
    let genericName: String?
    let indications: String?
    let dosageAndAdministration: String?
    let warnings: String?
    let adverseReactions: String?
    let sourceURL: String
}

final class OpenFDADrugService: DrugRemoteService {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.fda.gov/drug/label.json")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchInfo(for query: String) async throws -> OpenFDADrug? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // openFDA search expression. Lucene-style; URLComponents percent-encodes
        // the value (`+`, `"`, `:`) so the literal query string lands intact.
        let term = trimmed.lowercased()
        let searchExpr = "openfda.brand_name:\"\(term)\"+OR+openfda.generic_name:\"\(term)\""

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "search", value: searchExpr),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8.0)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        // openFDA returns 404 with `{"error": ...}` when zero matches; that's
        // not an error from our perspective — it just means "not found".
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(OpenFDAResponse.self, from: data)
        return payload.results.first?.toDrug()
    }

    // MARK: - Wire format

    private struct OpenFDAResponse: Decodable {
        let results: [Raw]

        struct Raw: Decodable {
            let openfda: Meta?
            let indicationsAndUsage: [String]?
            let purpose: [String]?
            let dosageAndAdministration: [String]?
            let warnings: [String]?
            let adverseReactions: [String]?

            struct Meta: Decodable {
                let brandName: [String]?
                let genericName: [String]?
                let splId: [String]?
                let splSetId: [String]?
            }

            func toDrug() -> OpenFDADrug {
                let brand = openfda?.brandName?.first
                let generic = openfda?.genericName?.first
                let setId = openfda?.splSetId?.first ?? openfda?.splId?.first

                let sourceURL: String
                if let setId, !setId.isEmpty {
                    sourceURL = "https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=\(setId)"
                } else {
                    let queryTerm = brand ?? generic ?? ""
                    let escaped = queryTerm
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    sourceURL = "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query=\(escaped)"
                }

                let indications = (purpose?.first?.isEmpty == false ? purpose?.first : nil)
                    ?? indicationsAndUsage?.first

                return OpenFDADrug(
                    brandName: brand,
                    genericName: generic,
                    indications: indications,
                    dosageAndAdministration: dosageAndAdministration?.first,
                    warnings: warnings?.first,
                    adverseReactions: adverseReactions?.first,
                    sourceURL: sourceURL
                )
            }
        }
    }
}
