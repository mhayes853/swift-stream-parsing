import Foundation
import StreamParsing

// Models for the real-world corpora, each both `@StreamParseable` and `Codable`, so the stream
// parser's answer can be checked against `JSONDecoder`'s for the very same declaration. They are
// the benchmark package's models (`Benchmarks/StreamParsingBenchmarks/Models.swift`), renamed:
// keeping the two in step means a benchmark row and an acceptance row describe the same work.
//
// The stream models default every member, because an incomplete stream is valid input. Codable
// synthesis ignores those defaults when a key is absent, so the few heterogeneous objects in the
// corpora get the same default-on-missing behaviour explicitly at the bottom of this file.

@StreamParseable
struct CorpusCanada: Hashable, Sendable, Codable {
  var type: String = ""
  var features: [CorpusCanadaFeature] = []
}

@StreamParseable
struct CorpusCanadaFeature: Hashable, Sendable, Codable {
  var type: String = ""
  var properties: CorpusCanadaProperties = CorpusCanadaProperties()
  var geometry: CorpusCanadaGeometry = CorpusCanadaGeometry()
}

@StreamParseable
struct CorpusCanadaProperties: Hashable, Sendable, Codable {
  var name: String = ""
}

@StreamParseable
struct CorpusCanadaGeometry: Hashable, Sendable, Codable {
  var type: String = ""
  var coordinates: [[SIMD2<Double>]] = []
}

@StreamParseable
struct CorpusMesh: Hashable, Sendable, Codable {
  var batches: [CorpusMeshBatch] = []
  var positions: [Double] = []
  var tex0: [Double] = []
  var colors: [Int] = []
  var influences: [SIMD2<Double>] = []
  var normals: [Double] = []
  var indices: [Int] = []
}

@StreamParseable
struct CorpusMeshBatch: Hashable, Sendable, Codable {
  var indexRange: [Int] = []
  var vertexRange: [Int] = []
  var usedBones: [Int] = []
}

@StreamParseable
struct CorpusGSoCProject: Hashable, Sendable, Codable {
  var name: String = ""
  var description: String = ""
  var sponsor: CorpusGSoCOrganization = CorpusGSoCOrganization()
  var author: CorpusGSoCOrganization = CorpusGSoCOrganization()
}

@StreamParseable
struct CorpusGSoCOrganization: Hashable, Sendable, Codable {
  var name: String = ""
  var disambiguatingDescription: String = ""
  var description: String = ""
  var url: String = ""
  var logo: String = ""
}

@StreamParseable
struct CorpusGitHubEvent: Hashable, Sendable, Codable {
  var type: String = ""
  var created_at: String = ""
  var actor: CorpusGitHubActor = CorpusGitHubActor()
  var repo: CorpusGitHubRepository = CorpusGitHubRepository()
  var payload: CorpusGitHubPayload = CorpusGitHubPayload()
  var id: String = ""
}

@StreamParseable
struct CorpusGitHubActor: Hashable, Sendable, Codable {
  var gravatar_id: String = ""
  var login: String = ""
  var avatar_url: String = ""
  var url: String = ""
  var id: Int = 0
}

@StreamParseable
struct CorpusGitHubRepository: Hashable, Sendable, Codable {
  var url: String = ""
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct CorpusGitHubPayload: Hashable, Sendable, Codable {
  var commits: [CorpusGitHubCommit] = []
  var distinct_size: Int = 0
  var ref: String = ""
  var push_id: Int = 0
  var head: String = ""
  var before: String = ""
  var size: Int = 0
}

@StreamParseable
struct CorpusGitHubCommit: Hashable, Sendable, Codable {
  var url: String = ""
  var message: String = ""
  var distinct: Bool = false
  var sha: String = ""
  var author: CorpusGitHubCommitAuthor = CorpusGitHubCommitAuthor()
}

@StreamParseable
struct CorpusGitHubCommitAuthor: Hashable, Sendable, Codable {
  var email: String = ""
  var name: String = ""
}

@StreamParseable
struct CorpusCITM: Equatable, Codable {
  var areaNames: [String: String] = [:]
  var seatCategoryNames: [String: String] = [:]
  var events: [String: CorpusCITMEvent] = [:]
  var performances: [CorpusCITMPerformance] = []
}

@StreamParseable
struct CorpusCITMEvent: Equatable, Codable {
  var id: Int = 0
  var name: String = ""
  var subTopicIds: [Int] = []
  var topicIds: [Int] = []
}

@StreamParseable
struct CorpusCITMPerformance: Equatable, Codable {
  var eventId: Int = 0
  var id: Int = 0
  var start: Int = 0
  var venueCode: String = ""
  var prices: [CorpusCITMPrice] = []
  var seatCategories: [CorpusCITMSeatCategory] = []
}

@StreamParseable
struct CorpusCITMPrice: Equatable, Codable {
  var amount: Int = 0
  var audienceSubCategoryId: Int = 0
  var seatCategoryId: Int = 0
}

@StreamParseable
struct CorpusCITMSeatCategory: Equatable, Codable {
  var seatCategoryId: Int = 0
  var areas: [CorpusCITMArea] = []
}

@StreamParseable
struct CorpusCITMArea: Equatable, Codable {
  var areaId: Int = 0
  var blockIds: [Int] = []
}

@StreamParseable
struct CorpusTwitterFull: Equatable, Codable {
  var statuses: [CorpusTweetFull] = []
}

@StreamParseable
struct CorpusTweetFull: Equatable, Codable {
  var metadata: CorpusTwitterMetadata = CorpusTwitterMetadata()
  var created_at: String = ""
  var id: Int = 0
  var id_str: String = ""
  var text: String = ""
  var source: String = ""
  var truncated: Bool = false
  var in_reply_to_status_id: Int? = nil
  var in_reply_to_status_id_str: String? = nil
  var in_reply_to_user_id: Int? = nil
  var in_reply_to_user_id_str: String? = nil
  var in_reply_to_screen_name: String? = nil
  var user: CorpusTwitterUserFull = CorpusTwitterUserFull()
  var geo: String? = nil
  var coordinates: String? = nil
  var place: String? = nil
  var contributors: String? = nil
  var retweet_count: Int = 0
  var favorite_count: Int = 0
  var entities: CorpusTwitterEntities = CorpusTwitterEntities()
  var favorited: Bool = false
  var retweeted: Bool = false
  var possibly_sensitive: Bool? = nil
  var lang: String = ""
  var retweeted_status: CorpusRetweetedStatusFull? = nil
}

@StreamParseable
struct CorpusRetweetedStatusFull: Equatable, Codable {
  var metadata: CorpusTwitterMetadata = CorpusTwitterMetadata()
  var created_at: String = ""
  var id: Int = 0
  var id_str: String = ""
  var text: String = ""
  var source: String = ""
  var truncated: Bool = false
  var in_reply_to_status_id: Int? = nil
  var in_reply_to_status_id_str: String? = nil
  var in_reply_to_user_id: Int? = nil
  var in_reply_to_user_id_str: String? = nil
  var in_reply_to_screen_name: String? = nil
  var user: CorpusTwitterUserFull = CorpusTwitterUserFull()
  var geo: String? = nil
  var coordinates: String? = nil
  var place: String? = nil
  var contributors: String? = nil
  var retweet_count: Int = 0
  var favorite_count: Int = 0
  var entities: CorpusTwitterEntities = CorpusTwitterEntities()
  var favorited: Bool = false
  var retweeted: Bool = false
  var possibly_sensitive: Bool? = nil
  var lang: String = ""
}

@StreamParseable
struct CorpusTwitterMetadata: Equatable, Codable {
  var result_type: String = ""
  var iso_language_code: String = ""
}

@StreamParseable
struct CorpusTwitterUserFull: Equatable, Codable {
  var id: Int = 0
  var id_str: String = ""
  var name: String = ""
  var screen_name: String = ""
  var location: String = ""
  var description: String = ""
  var url: String? = nil
  var entities: CorpusTwitterUserEntities = CorpusTwitterUserEntities()
  var protected: Bool = false
  var followers_count: Int = 0
  var friends_count: Int = 0
  var listed_count: Int = 0
  var created_at: String = ""
  var favourites_count: Int = 0
  var utc_offset: Int? = nil
  var time_zone: String? = nil
  var geo_enabled: Bool = false
  var verified: Bool = false
  var statuses_count: Int = 0
  var lang: String = ""
  var contributors_enabled: Bool = false
  var is_translator: Bool = false
  var is_translation_enabled: Bool = false
  var profile_background_color: String = ""
  var profile_background_image_url: String = ""
  var profile_background_image_url_https: String = ""
  var profile_background_tile: Bool = false
  var profile_image_url: String = ""
  var profile_image_url_https: String = ""
  var profile_banner_url: String? = nil
  var profile_link_color: String = ""
  var profile_sidebar_border_color: String = ""
  var profile_sidebar_fill_color: String = ""
  var profile_text_color: String = ""
  var profile_use_background_image: Bool = false
  var default_profile: Bool = false
  var default_profile_image: Bool = false
  var following: Bool = false
  var follow_request_sent: Bool = false
  var notifications: Bool = false
}

@StreamParseable
struct CorpusTwitterUserEntities: Equatable, Codable {
  var description: CorpusTwitterURLList = CorpusTwitterURLList()
  var url: CorpusTwitterURLList? = nil
}

@StreamParseable
struct CorpusTwitterURLList: Equatable, Codable {
  var urls: [CorpusTwitterURLEntity] = []
}

@StreamParseable
struct CorpusTwitterURLEntity: Equatable, Codable {
  var url: String = ""
  var expanded_url: String = ""
  var display_url: String = ""
  var indices: [Int] = []
}

@StreamParseable
struct CorpusTwitterEntities: Equatable, Codable {
  var hashtags: [CorpusTwitterHashtag] = []
  var symbols: [CorpusTwitterHashtag] = []
  var urls: [CorpusTwitterURLEntity] = []
  var user_mentions: [CorpusTwitterUserMention] = []
  var media: [CorpusTwitterMedia] = []
}

@StreamParseable
struct CorpusTwitterHashtag: Equatable, Codable {
  var text: String = ""
  var indices: [Int] = []
}

@StreamParseable
struct CorpusTwitterUserMention: Equatable, Codable {
  var screen_name: String = ""
  var name: String = ""
  var id: Int = 0
  var id_str: String = ""
  var indices: [Int] = []
}

@StreamParseable
struct CorpusTwitterMedia: Equatable, Codable {
  var id: Int = 0
  var id_str: String = ""
  var indices: [Int] = []
  var media_url: String = ""
  var media_url_https: String = ""
  var url: String = ""
  var display_url: String = ""
  var expanded_url: String = ""
  var type: String = ""
  var sizes: CorpusTwitterMediaSizes = CorpusTwitterMediaSizes()
  var source_status_id: Int? = nil
  var source_status_id_str: String? = nil
}

@StreamParseable
struct CorpusTwitterMediaSizes: Equatable, Codable {
  var thumb: CorpusTwitterMediaSize = CorpusTwitterMediaSize()
  var small: CorpusTwitterMediaSize = CorpusTwitterMediaSize()
  var medium: CorpusTwitterMediaSize = CorpusTwitterMediaSize()
  var large: CorpusTwitterMediaSize = CorpusTwitterMediaSize()
}

@StreamParseable
struct CorpusTwitterMediaSize: Equatable, Codable {
  var w: Int = 0
  var h: Int = 0
  var resize: String = ""
}

@StreamParseable
struct CorpusTwitterMatched: Equatable, Codable {
  var statuses: [CorpusTweetMatched] = []
}

@StreamParseable
struct CorpusTweetMatched: Equatable, Codable {
  var id: Int = 0
  var text: String = ""
  var user: CorpusTwitterUserMatched = CorpusTwitterUserMatched()
}

@StreamParseable
struct CorpusTwitterUserMatched: Equatable, Codable {
  var name: String = ""
  var screen_name: String = ""
  var followers_count: Int = 0
}

// MARK: - LLM message

// The corpus is an assistant message in the Anthropic Messages wire format: the shape a
// structured-output consumer of this library actually streams. `role` and `stop_reason` are
// string-raw enums so the real document exercises enum resolution, not just strings.
@StreamParseable
struct CorpusLLMMessage: Equatable, Codable {
  var id: String = ""
  var type: String = ""
  var role: CorpusLLMRole = .unknown
  var model: String = ""
  var content: [CorpusLLMContentBlock] = []
  var stop_reason: CorpusLLMStopReason = .unknown
  var stop_sequence: String? = nil
  var usage: CorpusLLMUsage = CorpusLLMUsage()
}

@StreamParseable
enum CorpusLLMRole: String, Equatable, Codable {
  @StreamParseableDefault
  case unknown
  case user
  case assistant
}

@StreamParseable
enum CorpusLLMStopReason: String, Equatable, Codable {
  @StreamParseableDefault
  case unknown
  case end_turn
  case max_tokens
  case stop_sequence
  case tool_use
}

// 546 `text` blocks and 90 `tool_use` blocks (`id`, `name`, and an arbitrary `input` object the
// model does not name, so it is skipped). Members only one kind carries are optional, so the
// strict conversion can succeed on the whole message.
@StreamParseable
struct CorpusLLMContentBlock: Equatable, Codable {
  var type: String = ""
  var text: String? = nil
  var id: String? = nil
  var name: String? = nil
}

@StreamParseable
struct CorpusLLMUsage: Equatable, Codable {
  var input_tokens: Int = 0
  var output_tokens: Int = 0
  var cache_creation_input_tokens: Int = 0
  var cache_read_input_tokens: Int = 0
}

// MARK: - GitHub events, through a key decoding strategy

// The same corpus as `CorpusGitHubEvent`, declared with Swift-cased names and read through
// `.convertFromSnakeCase`, so it can be checked against `JSONDecoder`'s own strategy.
@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
struct CorpusGitHubEventCamel: Equatable, Codable {
  var type: String = ""
  var createdAt: String = ""
  var actor: CorpusGitHubActorCamel = CorpusGitHubActorCamel()
  var repo: CorpusGitHubRepositoryCamel = CorpusGitHubRepositoryCamel()
  var id: String = ""
}

@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
struct CorpusGitHubActorCamel: Equatable, Codable {
  var gravatarId: String = ""
  var login: String = ""
  var avatarUrl: String = ""
  var url: String = ""
  var id: Int = 0
}

@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
struct CorpusGitHubRepositoryCamel: Equatable, Codable {
  var url: String = ""
  var id: Int = 0
  var name: String = ""
}

// MARK: - Default-on-missing decoding

extension KeyedDecodingContainer {
  fileprivate func decodeDefault<T: Decodable>(
    _ type: T.Type, forKey key: Key, default value: T
  ) throws -> T {
    try decodeIfPresent(type, forKey: key) ?? value
  }
}

extension CorpusGSoCProject {
  private enum CodingKeys: String, CodingKey {
    case name, description, sponsor, author
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decodeDefault(String.self, forKey: .name, default: ""),
      description: try container.decodeDefault(String.self, forKey: .description, default: ""),
      sponsor: try container.decodeDefault(
        CorpusGSoCOrganization.self, forKey: .sponsor, default: .init()
      ),
      author: try container.decodeDefault(
        CorpusGSoCOrganization.self, forKey: .author, default: .init()
      )
    )
  }
}

extension CorpusGSoCOrganization {
  private enum CodingKeys: String, CodingKey {
    case name, disambiguatingDescription, description, url, logo
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decodeDefault(String.self, forKey: .name, default: ""),
      disambiguatingDescription: try container.decodeDefault(
        String.self, forKey: .disambiguatingDescription, default: ""
      ),
      description: try container.decodeDefault(String.self, forKey: .description, default: ""),
      url: try container.decodeDefault(String.self, forKey: .url, default: ""),
      logo: try container.decodeDefault(String.self, forKey: .logo, default: "")
    )
  }
}

extension CorpusGitHubPayload {
  private enum CodingKeys: String, CodingKey {
    case commits, distinct_size, ref, push_id, head, before, size
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      commits: try container.decodeDefault(
        [CorpusGitHubCommit].self, forKey: .commits, default: []
      ),
      distinct_size: try container.decodeDefault(Int.self, forKey: .distinct_size, default: 0),
      ref: try container.decodeDefault(String.self, forKey: .ref, default: ""),
      push_id: try container.decodeDefault(Int.self, forKey: .push_id, default: 0),
      head: try container.decodeDefault(String.self, forKey: .head, default: ""),
      before: try container.decodeDefault(String.self, forKey: .before, default: ""),
      size: try container.decodeDefault(Int.self, forKey: .size, default: 0)
    )
  }
}

// `entities.media` is present on only a minority of statuses.
extension CorpusTwitterEntities {
  private enum CodingKeys: String, CodingKey {
    case hashtags, symbols, urls, user_mentions, media
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      hashtags: try container.decodeDefault(
        [CorpusTwitterHashtag].self, forKey: .hashtags, default: []
      ),
      symbols: try container.decodeDefault(
        [CorpusTwitterHashtag].self, forKey: .symbols, default: []
      ),
      urls: try container.decodeDefault(
        [CorpusTwitterURLEntity].self, forKey: .urls, default: []
      ),
      user_mentions: try container.decodeDefault(
        [CorpusTwitterUserMention].self, forKey: .user_mentions, default: []
      ),
      media: try container.decodeDefault(
        [CorpusTwitterMedia].self, forKey: .media, default: []
      )
    )
  }
}

// MARK: - Partial equality

// Snapshots are compared directly in the streaming-semantics suite.
extension CorpusCanada.Partial: Equatable {}
extension CorpusCanadaFeature.Partial: Equatable {}
extension CorpusCanadaProperties.Partial: Equatable {}
extension CorpusCanadaGeometry.Partial: Equatable {}
extension CorpusMesh.Partial: Equatable {}
extension CorpusMeshBatch.Partial: Equatable {}
extension CorpusGSoCProject.Partial: Equatable {}
extension CorpusGSoCOrganization.Partial: Equatable {}
extension CorpusGitHubEvent.Partial: Equatable {}
extension CorpusGitHubActor.Partial: Equatable {}
extension CorpusGitHubRepository.Partial: Equatable {}
extension CorpusGitHubPayload.Partial: Equatable {}
extension CorpusGitHubCommit.Partial: Equatable {}
extension CorpusGitHubCommitAuthor.Partial: Equatable {}
extension CorpusCITM.Partial: Equatable {}
extension CorpusCITMEvent.Partial: Equatable {}
extension CorpusCITMPerformance.Partial: Equatable {}
extension CorpusCITMPrice.Partial: Equatable {}
extension CorpusCITMSeatCategory.Partial: Equatable {}
extension CorpusCITMArea.Partial: Equatable {}
extension CorpusTwitterFull.Partial: Equatable {}
extension CorpusTweetFull.Partial: Equatable {}
extension CorpusRetweetedStatusFull.Partial: Equatable {}
extension CorpusTwitterMetadata.Partial: Equatable {}
extension CorpusTwitterUserFull.Partial: Equatable {}
extension CorpusTwitterUserEntities.Partial: Equatable {}
extension CorpusTwitterURLList.Partial: Equatable {}
extension CorpusTwitterURLEntity.Partial: Equatable {}
extension CorpusTwitterEntities.Partial: Equatable {}
extension CorpusTwitterHashtag.Partial: Equatable {}
extension CorpusTwitterUserMention.Partial: Equatable {}
extension CorpusTwitterMedia.Partial: Equatable {}
extension CorpusTwitterMediaSizes.Partial: Equatable {}
extension CorpusTwitterMediaSize.Partial: Equatable {}
extension CorpusTwitterMatched.Partial: Equatable {}
extension CorpusTweetMatched.Partial: Equatable {}
extension CorpusTwitterUserMatched.Partial: Equatable {}
extension CorpusLLMMessage.Partial: Equatable {}
extension CorpusLLMContentBlock.Partial: Equatable {}
extension CorpusLLMUsage.Partial: Equatable {}
extension CorpusGitHubEventCamel.Partial: Equatable {}
extension CorpusGitHubActorCamel.Partial: Equatable {}
extension CorpusGitHubRepositoryCamel.Partial: Equatable {}
