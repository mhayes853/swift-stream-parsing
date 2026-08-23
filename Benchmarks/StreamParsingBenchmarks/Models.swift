// Snake_case fields are deliberate: a model's member names must byte-match the JSON keys in the
// real payloads, or the benchmark measures the discard path instead of the write path.
import StreamParsing

// MARK: - Flat

@StreamParseable
struct BenchmarkProfile: Equatable {
  var id: Int = 0
  var name: String = ""
  var email: String = ""
  var age: Int = 0
  var score: Double = 0
  var isActive: Bool = false
}

// MARK: - Arrays

@StreamParseable
struct BenchmarkUser: Equatable {
  var id: Int = 0
  var name: String = ""
  var email: String = ""
}

@StreamParseable
struct BenchmarkUserList: Equatable {
  var users: [BenchmarkUser] = []
  var total: Int = 0
}

// MARK: - Schema width

// Forty-eight members, because key matching scans precomputed leading words and its cost is in
// the member count of the type rather than in the payload. Nothing else in the suite declares
// more than six.
@StreamParseable
struct BenchmarkWide: Equatable {
  var field0: Int = 0
  var field1: Int = 0
  var field2: Int = 0
  var field3: Int = 0
  var field4: Int = 0
  var field5: Int = 0
  var field6: Int = 0
  var field7: Int = 0
  var field8: Int = 0
  var field9: Int = 0
  var field10: Int = 0
  var field11: Int = 0
  var field12: Int = 0
  var field13: Int = 0
  var field14: Int = 0
  var field15: Int = 0
  var field16: Int = 0
  var field17: Int = 0
  var field18: Int = 0
  var field19: Int = 0
  var field20: Int = 0
  var field21: Int = 0
  var field22: Int = 0
  var field23: Int = 0
  var field24: Int = 0
  var field25: Int = 0
  var field26: Int = 0
  var field27: Int = 0
  var field28: Int = 0
  var field29: Int = 0
  var field30: Int = 0
  var field31: Int = 0
  var field32: Int = 0
  var field33: Int = 0
  var field34: Int = 0
  var field35: Int = 0
  var field36: Int = 0
  var field37: Int = 0
  var field38: Int = 0
  var field39: Int = 0
  var field40: Int = 0
  var field41: Int = 0
  var field42: Int = 0
  var field43: Int = 0
  var field44: Int = 0
  var field45: Int = 0
  var field46: Int = 0
  var field47: Int = 0
}

@StreamParseable
struct BenchmarkWideRows: Equatable {
  var rows: [BenchmarkWide] = []
}

// MARK: - Repeated container fields

// Container fields inside a repeated element, which no other model here has: every one of them
// declares its arrays and dictionaries on the root, so `enterField` runs for them once per
// document. Real responses do not look like that — twitter's `entities.hashtags`, `urls` and
// `user_mentions` are three container fields inside each of a hundred statuses — and `enterField`
// runs once per container *occurrence*, so that shape enters container fields hundreds of times
// where these models enter them once. Both element kinds are present because an array of a
// macro generated type resolves its element schema differently from an array of a scalar.

@StreamParseable
struct BenchmarkEntities: Equatable {
  var hashtags: [String] = []
  var mentions: [Int] = []
  var sizes: [String: Int] = [:]
}

@StreamParseable
struct BenchmarkEntry: Equatable {
  var id: Int = 0
  var entities: BenchmarkEntities = BenchmarkEntities()
}

@StreamParseable
struct BenchmarkEntryList: Equatable {
  var entries: [BenchmarkEntry] = []
}

// The same shape as `BenchmarkEntryList`, with every container field spelled through an alias
// the macro cannot see through. That routes container entry through `StreamContainerPartial`
// instead of the hoisted syntax path, which was the one route left minting a schema per
// container occurrence — and the one whose schema had no owner but the frame.
typealias BenchmarkAliasedTags = [String]
typealias BenchmarkAliasedMentions = [Int]
typealias BenchmarkAliasedSizes = [String: Int]

@StreamParseable
struct BenchmarkAliasedEntities: Equatable {
  var hashtags: BenchmarkAliasedTags = []
  var mentions: BenchmarkAliasedMentions = []
  var sizes: BenchmarkAliasedSizes = [:]
}

@StreamParseable
struct BenchmarkAliasedEntry: Equatable {
  var id: Int = 0
  var entities: BenchmarkAliasedEntities = BenchmarkAliasedEntities()
}

@StreamParseable
struct BenchmarkAliasedEntryList: Equatable {
  var entries: [BenchmarkAliasedEntry] = []
}

// MARK: - Numbers

@StreamParseable
struct BenchmarkIntegers: Equatable {
  var values: [UInt64] = []
}

@StreamParseable
struct BenchmarkFloats: Equatable {
  var values: [Double] = []
}

// MARK: - Dictionaries

@StreamParseable
struct BenchmarkCounts: Equatable {
  var counts: [String: Int] = [:]
}

// MARK: - Canada

@StreamParseable
struct BenchmarkCanada: Hashable, Sendable {
  var type: String = ""
  var features: [BenchmarkCanadaFeature] = []
}

@StreamParseable
struct BenchmarkCanadaFeature: Hashable, Sendable {
  var type: String = ""
  var properties: BenchmarkCanadaProperties = BenchmarkCanadaProperties()
  var geometry: BenchmarkCanadaGeometry = BenchmarkCanadaGeometry()
}

@StreamParseable
struct BenchmarkCanadaProperties: Hashable, Sendable {
  var name: String = ""
}

@StreamParseable
struct BenchmarkCanadaGeometry: Hashable, Sendable {
  var type: String = ""
  var coordinates: [[SIMD2<Double>]] = []
}

// The representation Canada used before fixed-width coordinate pairs were available. Keep it as
// a permanent control: unlike the SIMD model, every pair is another independently allocated
// `StreamArray`, so future improvements to the generic nested-array path remain measurable.
@StreamParseable
struct BenchmarkCanadaDynamic: Hashable, Sendable {
  var type: String = ""
  var features: [BenchmarkCanadaDynamicFeature] = []
}

@StreamParseable
struct BenchmarkCanadaDynamicFeature: Hashable, Sendable {
  var type: String = ""
  var properties: BenchmarkCanadaProperties = BenchmarkCanadaProperties()
  var geometry: BenchmarkCanadaDynamicGeometry = BenchmarkCanadaDynamicGeometry()
}

@StreamParseable
struct BenchmarkCanadaDynamicGeometry: Hashable, Sendable {
  var type: String = ""
  var coordinates: [[[Double]]] = []
}

// MARK: - Mesh

// A three.js mesh export: one object of long flat numeric arrays. The model keeps every one of
// them, because the point of the payload is its number mix -- `positions` and `normals` are
// decimals, `indices` and `colors` are integers, and they interleave down the document rather
// than sitting in separate regions. `colors` holds packed ARGB words above `Int32.max`, so it is
// `Int` rather than the narrower type the values look like they want.
//
// `influences` is `[SIMD2<Double>]`, not an integer vector: its pairs are written `[1.0,0]`,
// mixing a decimal and an integer inside one array, and an `Int` lane rejects the decimal on its
// `.fraction` flag. That is the payload's point -- shapes vary within a single array, not just
// between fields -- and it is what the `positions?.count` preconditions below exist to catch.
//
// `morphTargets` is an empty object in the document and is deliberately not modelled; the parser
// skips unmatched keys, which is also what keeps this model honest about the skip path.
@StreamParseable
struct BenchmarkMesh: Hashable, Sendable {
  var batches: [BenchmarkMeshBatch] = []
  var positions: [Double] = []
  var tex0: [Double] = []
  var colors: [Int] = []
  var influences: [SIMD2<Double>] = []
  var normals: [Double] = []
  var indices: [Int] = []
}

// The old nested representation of `influences`, retained beside the optimized model for the
// same reason as Canada's dynamic coordinates. The other fields deliberately remain identical.
@StreamParseable
struct BenchmarkMeshDynamic: Hashable, Sendable {
  var batches: [BenchmarkMeshBatch] = []
  var positions: [Double] = []
  var tex0: [Double] = []
  var colors: [Int] = []
  var influences: [[Double]] = []
  var normals: [Double] = []
  var indices: [Int] = []
}

@StreamParseable
struct BenchmarkMeshBatch: Hashable, Sendable {
  var indexRange: [Int] = []
  var vertexRange: [Int] = []
  var usedBones: [Int] = []
}

// MARK: - GSoC 2018

// The document is a dictionary keyed by numeric project identifiers. Keys beginning with `@`
// cannot be represented as Swift member names and are intentionally ignored; the fields below
// retain the long string values and nested organizations which define this corpus's shape.
@StreamParseable
struct BenchmarkGSoCProject: Hashable, Sendable {
  var name: String = ""
  var description: String = ""
  var sponsor: BenchmarkGSoCOrganization = BenchmarkGSoCOrganization()
  var author: BenchmarkGSoCOrganization = BenchmarkGSoCOrganization()
}

@StreamParseable
struct BenchmarkGSoCOrganization: Hashable, Sendable {
  var name: String = ""
  var disambiguatingDescription: String = ""
  var description: String = ""
  var url: String = ""
  var logo: String = ""
}

// MARK: - GitHub events

// swiftlint:disable identifier_name
@StreamParseable
struct BenchmarkGitHubEvent: Hashable, Sendable {
  var type: String = ""
  var created_at: String = ""
  var actor: BenchmarkGitHubActor = BenchmarkGitHubActor()
  var repo: BenchmarkGitHubRepository = BenchmarkGitHubRepository()
  var payload: BenchmarkGitHubPayload = BenchmarkGitHubPayload()
  var id: String = ""
}

@StreamParseable
struct BenchmarkGitHubActor: Hashable, Sendable {
  var gravatar_id: String = ""
  var login: String = ""
  var avatar_url: String = ""
  var url: String = ""
  var id: Int = 0
}

@StreamParseable
struct BenchmarkGitHubRepository: Hashable, Sendable {
  var url: String = ""
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct BenchmarkGitHubPayload: Hashable, Sendable {
  var commits: [BenchmarkGitHubCommit] = []
  var distinct_size: Int = 0
  var ref: String = ""
  var push_id: Int = 0
  var head: String = ""
  var before: String = ""
  var size: Int = 0
}

@StreamParseable
struct BenchmarkGitHubCommit: Hashable, Sendable {
  var url: String = ""
  var message: String = ""
  var distinct: Bool = false
  var sha: String = ""
  var author: BenchmarkGitHubCommitAuthor = BenchmarkGitHubCommitAuthor()
}

@StreamParseable
struct BenchmarkGitHubCommitAuthor: Hashable, Sendable {
  var email: String = ""
  var name: String = ""
}
// swiftlint:enable identifier_name

// MARK: - CITM catalog

// The one real payload whose top level is dictionaries — `events` alone is 184 dynamic keys —
// so this is the model that routes real data through `StreamDictionary._openValue` rather than
// through the synthetic `Dictionary` rows.
@StreamParseable
struct BenchmarkCITM: Equatable {
  var areaNames: [String: String] = [:]
  var seatCategoryNames: [String: String] = [:]
  var events: [String: BenchmarkCITMEvent] = [:]
  var performances: [BenchmarkCITMPerformance] = []
}

@StreamParseable
struct BenchmarkCITMEvent: Equatable {
  var id: Int = 0
  var name: String = ""
  var subTopicIds: [Int] = []
  var topicIds: [Int] = []
}

@StreamParseable
struct BenchmarkCITMPerformance: Equatable {
  var eventId: Int = 0
  var id: Int = 0
  var start: Int = 0
  var venueCode: String = ""
  var prices: [BenchmarkCITMPrice] = []
  var seatCategories: [BenchmarkCITMSeatCategory] = []
}

@StreamParseable
struct BenchmarkCITMPrice: Equatable {
  var amount: Int = 0
  var audienceSubCategoryId: Int = 0
  var seatCategoryId: Int = 0
}

@StreamParseable
struct BenchmarkCITMSeatCategory: Equatable {
  var seatCategoryId: Int = 0
  var areas: [BenchmarkCITMArea] = []
}

@StreamParseable
struct BenchmarkCITMArea: Equatable {
  var areaId: Int = 0
  var blockIds: [Int] = []
}

// MARK: - Twitter

@StreamParseable
struct BenchmarkTwitter: Equatable {
  var statuses: [BenchmarkTweet] = []
}

@StreamParseable
struct BenchmarkTweet: Equatable {
  var id: Int = 0
  var text: String = ""
  var user: BenchmarkTwitterUser = BenchmarkTwitterUser()
}

@StreamParseable
struct BenchmarkTwitterUser: Equatable {
  var name: String = ""
  var screenName: String = ""
  var followersCount: Int = 0
}

// `BenchmarkTwitterUser.screenName` and `.followersCount` never match the payload's snake_case
// keys, so that benchmark measures more of the discard path than it appears to. This variant
// declares the keys the payload actually contains, keeping the write path measured alongside it.
@StreamParseable
struct BenchmarkTwitterMatched: Equatable {
  var statuses: [BenchmarkTweetMatched] = []
}

@StreamParseable
struct BenchmarkTweetMatched: Equatable {
  var id: Int = 0
  var text: String = ""
  var user: BenchmarkTwitterUserMatched = BenchmarkTwitterUserMatched()
}

// swiftlint:disable identifier_name
@StreamParseable
struct BenchmarkTwitterUserMatched: Equatable {
  var name: String = ""
  var screen_name: String = ""
  var followers_count: Int = 0
}

// The same container spine as `BenchmarkTwitterMatched`, with every scalar key renamed so that no
// scalar ever matches. Containers are still entered and elements still appended, so the difference
// against the matched model is what materializing the values costs — `String` construction and
// number conversion — with the routing that reaches them held constant.
@StreamParseable
struct BenchmarkTwitterStructure: Equatable {
  var statuses: [BenchmarkTweetStructure] = []
}

@StreamParseable
struct BenchmarkTweetStructure: Equatable {
  var absent_scalar: Int = 0
  var user: BenchmarkTwitterUserStructure = BenchmarkTwitterUserStructure()
}

@StreamParseable
struct BenchmarkTwitterUserStructure: Equatable {
  var absent_scalar: Int = 0
}

// MARK: - LLM message

@StreamParseable
struct BenchmarkLLMMessage: Equatable {
  var id: String = ""
  var role: String = ""
  var model: String = ""
  var content: [BenchmarkContentBlock] = []
  var stop_reason: String = ""
  var usage: BenchmarkUsage = BenchmarkUsage()
}

@StreamParseable
struct BenchmarkContentBlock: Equatable {
  var type: String = ""
  var text: String = ""
  var name: String = ""
}

@StreamParseable
struct BenchmarkUsage: Equatable {
  var input_tokens: Int = 0
  var output_tokens: Int = 0
}

// `BenchmarkLLMMessage`'s spine with the scalars renamed, for the same split as
// `BenchmarkTwitterStructure`. This is the payload where the answer matters most: it is the one
// dominated by long escaped strings, so it is where `String` materialization should show up.
@StreamParseable
struct BenchmarkLLMMessageStructure: Equatable {
  var content: [BenchmarkContentBlockStructure] = []
  var usage: BenchmarkUsageStructure = BenchmarkUsageStructure()
}

@StreamParseable
struct BenchmarkContentBlockStructure: Equatable {
  var absent_scalar: Int = 0
}

@StreamParseable
struct BenchmarkUsageStructure: Equatable {
  var absent_scalar: Int = 0
}
// swiftlint:enable identifier_name

// MARK: - Long strings

@StreamParseable
struct BenchmarkDocument: Equatable {
  var title: String = ""
  var body: String = ""
}

// MARK: - Structure only controls

// The `no values` control for a dictionary.
//
// Every other structure-only model renames its scalar keys so nothing matches, and that trick
// cannot work on a dictionary: a dictionary matches every key by construction, and a value its
// schema refuses is a type mismatch rather than an ignored key, so the parse would fail instead
// of routing. The control has to sit one level lower — the entry is still opened under its key,
// and the schema that receives the token accepts it and writes nothing.
//
// So the dictionary split is narrower than the object one: it holds `enterKey` and the entry's
// storage constant and removes only the scalar conversion. That is the honest reading, and it is
// the one that matters, because whether the dictionary path costs what it costs in `enterKey` or
// in the conversion is exactly the open question.
//
// One `Int` of storage, so the dictionary grows the same way it does with the real value type.
//
// `StreamParseableObject` rather than `StreamParseableRoot`, which is the non-obvious part.
// `_streamSchema(for:)` picks a schema by overload rather than by conformance, and a
// `StreamParseableRoot` matching none of the convertible overloads lands on the disfavored
// catch-all — a scalar schema that refuses every token. The custom `streamSchema` below is never
// read, and the row records a type mismatch instead of a parse. Only the `StreamParseableObject`
// overload forwards to `T.streamSchema`.
struct BenchmarkDiscardedScalar: Equatable, StreamInitializable, StreamParseableObject {
  var value: Int = 0

  static func streamInitialValue() -> Self { Self() }

  static var streamSchema: StreamSchema {
    StreamSchema(
      shape: .scalar,
      applyString: { _, _, _ in true },
      applyNumber: { _, _, _, _ in true },
      applyBoolean: { _, _, _ in true },
      applyNull: { _, _ in true }
    )
  }
}

extension BenchmarkDiscardedScalar: StreamParseable {
  typealias Partial = Self
}

// swiftlint:disable identifier_name

// `BenchmarkUserList`'s spine with the scalars renamed, like `BenchmarkTwitterStructure`. The
// array is still entered and all 100 elements are still appended.
@StreamParseable
struct BenchmarkUserListStructure: Equatable {
  var users: [BenchmarkUserStructure] = []
  var absent_total: Int = 0
}

@StreamParseable
struct BenchmarkUserStructure: Equatable {
  var absent_scalar: Int = 0
}

// `BenchmarkCounts` with the dictionary's value discarded rather than converted.
@StreamParseable
struct BenchmarkCountsStructure: Equatable {
  var counts: [String: BenchmarkDiscardedScalar] = [:]
}

// `BenchmarkCITM`'s spine. The two `[String: String]` maps and the object map keep their shape
// and lose their values through `BenchmarkDiscardedScalar`; the object subtrees rename their
// scalars the way `BenchmarkTwitterStructure` does. Containers are entered, elements appended and
// dictionary entries opened exactly as the matched model does.
@StreamParseable
struct BenchmarkCITMStructure: Equatable {
  var areaNames: [String: BenchmarkDiscardedScalar] = [:]
  var seatCategoryNames: [String: BenchmarkDiscardedScalar] = [:]
  var events: [String: BenchmarkCITMEventStructure] = [:]
  var performances: [BenchmarkCITMPerformanceStructure] = []
}

@StreamParseable
struct BenchmarkCITMEventStructure: Equatable {
  var absent_scalar: Int = 0
  var subTopicIds: [BenchmarkDiscardedScalar] = []
  var topicIds: [BenchmarkDiscardedScalar] = []
}

@StreamParseable
struct BenchmarkCITMPerformanceStructure: Equatable {
  var absent_scalar: Int = 0
  var prices: [BenchmarkCITMPriceStructure] = []
  var seatCategories: [BenchmarkCITMSeatCategoryStructure] = []
}

@StreamParseable
struct BenchmarkCITMPriceStructure: Equatable {
  var absent_scalar: Int = 0
}

@StreamParseable
struct BenchmarkCITMSeatCategoryStructure: Equatable {
  var absent_scalar: Int = 0
  var areas: [BenchmarkCITMAreaStructure] = []
}

@StreamParseable
struct BenchmarkCITMAreaStructure: Equatable {
  var absent_scalar: Int = 0
  var blockIds: [BenchmarkDiscardedScalar] = []
}

// swiftlint:enable identifier_name
