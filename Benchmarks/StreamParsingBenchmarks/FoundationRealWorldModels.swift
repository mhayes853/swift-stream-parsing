// Codable counterparts to the canonical real-world benchmark models. These intentionally live
// beside, rather than on, the streaming models: the streaming macro's defaults are meaningful
// for partial values, while JSONDecoder's synthesized Decodable implementation requires every
// non-optional member to be present. Optional scalar members retain the stream models' behavior
// for fields that are absent or null in only some members of a real-world corpus.

import Foundation

// MARK: - Twitter

struct CodableTwitterMatched: Codable {
  var statuses: [CodableTwitterMatchedTweet]?
}

struct CodableTwitterMatchedTweet: Codable {
  var id: Int?
  var text: String?
  var user: CodableTwitterMatchedUser?
}

struct CodableTwitterMatchedUser: Codable {
  var name: String?
  var screen_name: String?
  var followers_count: Int?
}

struct CodableTwitterFull: Codable {
  var statuses: [CodableTwitterFullTweet]?
}

struct CodableTwitterFullTweet: Codable {
  var metadata: CodableTwitterMetadata?
  var created_at: String?
  var id: Int?
  var id_str: String?
  var text: String?
  var source: String?
  var truncated: Bool?
  var in_reply_to_status_id: Int?
  var in_reply_to_status_id_str: String?
  var in_reply_to_user_id: Int?
  var in_reply_to_user_id_str: String?
  var in_reply_to_screen_name: String?
  var user: CodableTwitterUserFull?
  var geo: String?
  var coordinates: String?
  var place: String?
  var contributors: String?
  var retweet_count: Int?
  var favorite_count: Int?
  var entities: CodableTwitterEntities?
  var favorited: Bool?
  var retweeted: Bool?
  var possibly_sensitive: Bool?
  var lang: String?
  var retweeted_status: CodableTwitterRetweetedStatus?
}

struct CodableTwitterRetweetedStatus: Codable {
  var metadata: CodableTwitterMetadata?
  var created_at: String?
  var id: Int?
  var id_str: String?
  var text: String?
  var source: String?
  var truncated: Bool?
  var in_reply_to_status_id: Int?
  var in_reply_to_status_id_str: String?
  var in_reply_to_user_id: Int?
  var in_reply_to_user_id_str: String?
  var in_reply_to_screen_name: String?
  var user: CodableTwitterUserFull?
  var geo: String?
  var coordinates: String?
  var place: String?
  var contributors: String?
  var retweet_count: Int?
  var favorite_count: Int?
  var entities: CodableTwitterEntities?
  var favorited: Bool?
  var retweeted: Bool?
  var possibly_sensitive: Bool?
  var lang: String?
}

struct CodableTwitterMetadata: Codable {
  var result_type: String?
  var iso_language_code: String?
}

struct CodableTwitterUserFull: Codable {
  var id: Int?
  var id_str: String?
  var name: String?
  var screen_name: String?
  var location: String?
  var description: String?
  var url: String?
  var entities: CodableTwitterUserEntities?
  var protected: Bool?
  var followers_count: Int?
  var friends_count: Int?
  var listed_count: Int?
  var created_at: String?
  var favourites_count: Int?
  var utc_offset: Int?
  var time_zone: String?
  var geo_enabled: Bool?
  var verified: Bool?
  var statuses_count: Int?
  var lang: String?
  var contributors_enabled: Bool?
  var is_translator: Bool?
  var is_translation_enabled: Bool?
  var profile_background_color: String?
  var profile_background_image_url: String?
  var profile_background_image_url_https: String?
  var profile_background_tile: Bool?
  var profile_image_url: String?
  var profile_image_url_https: String?
  var profile_banner_url: String?
  var profile_link_color: String?
  var profile_sidebar_border_color: String?
  var profile_sidebar_fill_color: String?
  var profile_text_color: String?
  var profile_use_background_image: Bool?
  var default_profile: Bool?
  var default_profile_image: Bool?
  var following: Bool?
  var follow_request_sent: Bool?
  var notifications: Bool?
}

struct CodableTwitterUserEntities: Codable {
  var description: CodableTwitterURLList?
  var url: CodableTwitterURLList?
}

struct CodableTwitterURLList: Codable {
  var urls: [CodableTwitterURLEntity]?
}

struct CodableTwitterURLEntity: Codable {
  var url: String?
  var expanded_url: String?
  var display_url: String?
  var indices: [Int]?
}

struct CodableTwitterEntities: Codable {
  var hashtags: [CodableTwitterHashtag]?
  var symbols: [CodableTwitterHashtag]?
  var urls: [CodableTwitterURLEntity]?
  var user_mentions: [CodableTwitterUserMention]?
  var media: [CodableTwitterMedia]?
}

struct CodableTwitterHashtag: Codable {
  var text: String?
  var indices: [Int]?
}

struct CodableTwitterUserMention: Codable {
  var screen_name: String?
  var name: String?
  var id: Int?
  var id_str: String?
  var indices: [Int]?
}

struct CodableTwitterMedia: Codable {
  var id: Int?
  var id_str: String?
  var indices: [Int]?
  var media_url: String?
  var media_url_https: String?
  var url: String?
  var display_url: String?
  var expanded_url: String?
  var type: String?
  var sizes: CodableTwitterMediaSizes?
  var source_status_id: Int?
  var source_status_id_str: String?
}

struct CodableTwitterMediaSizes: Codable {
  var thumb: CodableTwitterMediaSize?
  var small: CodableTwitterMediaSize?
  var medium: CodableTwitterMediaSize?
  var large: CodableTwitterMediaSize?
}

struct CodableTwitterMediaSize: Codable {
  var w: Int?
  var h: Int?
  var resize: String?
}

// MARK: - Canada

struct CodableCanada: Codable {
  var type: String?
  var features: [CodableCanadaFeature]?
}

struct CodableCanadaFeature: Codable {
  var type: String?
  var properties: CodableCanadaProperties?
  var geometry: CodableCanadaGeometry?
}

struct CodableCanadaProperties: Codable {
  var name: String?
}

struct CodableCanadaGeometry: Codable {
  var type: String?
  var coordinates: [[SIMD2<Double>]]?
}

// MARK: - CITM catalog

struct CodableCITM: Codable {
  var areaNames: [String: String]?
  var seatCategoryNames: [String: String]?
  var events: [String: CodableCITMEvent]?
  var performances: [CodableCITMPerformance]?
}

struct CodableCITMEvent: Codable {
  var id: Int?
  var name: String?
  var subTopicIds: [Int]?
  var topicIds: [Int]?
}

struct CodableCITMPerformance: Codable {
  var eventId: Int?
  var id: Int?
  var start: Int?
  var venueCode: String?
  var prices: [CodableCITMPrice]?
  var seatCategories: [CodableCITMSeatCategory]?
}

struct CodableCITMPrice: Codable {
  var amount: Int?
  var audienceSubCategoryId: Int?
  var seatCategoryId: Int?
}

struct CodableCITMSeatCategory: Codable {
  var seatCategoryId: Int?
  var areas: [CodableCITMArea]?
}

struct CodableCITMArea: Codable {
  var areaId: Int?
  var blockIds: [Int]?
}

// MARK: - GSoC 2018

struct CodableGSoCProject: Codable {
  var name: String?
  var description: String?
  var sponsor: CodableGSoCOrganization?
  var author: CodableGSoCOrganization?
}

struct CodableGSoCOrganization: Codable {
  var name: String?
  var disambiguatingDescription: String?
  var description: String?
  var url: String?
  var logo: String?
}

// MARK: - GitHub events

struct CodableGitHubEvent: Codable {
  var type: String?
  var created_at: String?
  var actor: CodableGitHubActor?
  var repo: CodableGitHubRepository?
  var payload: CodableGitHubPayload?
  var id: String?
}

struct CodableGitHubActor: Codable {
  var gravatar_id: String?
  var login: String?
  var avatar_url: String?
  var url: String?
  var id: Int?
}

struct CodableGitHubRepository: Codable {
  var url: String?
  var id: Int?
  var name: String?
}

struct CodableGitHubPayload: Codable {
  var commits: [CodableGitHubCommit]?
  var distinct_size: Int?
  var ref: String?
  var push_id: Int?
  var head: String?
  var before: String?
  var size: Int?
}

struct CodableGitHubCommit: Codable {
  var url: String?
  var message: String?
  var distinct: Bool?
  var sha: String?
  var author: CodableGitHubCommitAuthor?
}

struct CodableGitHubCommitAuthor: Codable {
  var email: String?
  var name: String?
}

// MARK: - LLM message

struct CodableLLMMessage: Codable {
  var id: String?
  var role: String?
  var model: String?
  var content: [CodableContentBlock]?
  var stop_reason: String?
  var usage: CodableUsage?
}

struct CodableContentBlock: Codable {
  var type: String?
  var text: String?
  var name: String?
}

struct CodableUsage: Codable {
  var input_tokens: Int?
  var output_tokens: Int?
}

// MARK: - Qwen 3 structured output

struct CodableQwen3ToolCall: Codable {
  var name: String?
  var arguments: CodableQwen3ToolArguments?
}

struct CodableQwen3ToolArguments: Codable {
  var query: String?
  var path: String?
  var include: [String]?
  var exclude: [String]?
  var case_sensitive: Bool?
  var max_results: Int?
  var context: CodableQwen3SearchContext?
  var edits: [CodableQwen3WorkspaceEdit]?
}

struct CodableQwen3SearchContext: Codable {
  var before: Int?
  var after: Int?
  var languages: [String]?
}

struct CodableQwen3WorkspaceEdit: Codable {
  var path: String?
  var line: Int?
  var delete_count: Int?
  var replacement: String?
  var reason: String?
}

struct CodableQwen3StructuredResponse: Codable {
  var summary: String?
  var findings: [CodableQwen3Finding]?
  var recommendation: CodableQwen3Recommendation?
}

struct CodableQwen3Finding: Codable {
  var id: String?
  var severity: String?
  var path: String?
  var line: Int?
  var title: String?
  var detail: String?
  var tags: [String]?
}

struct CodableQwen3Recommendation: Codable {
  var decision: String?
  var confidence: Double?
  var steps: [String]?
}

// MARK: - Mesh

struct CodableMesh: Codable {
  var batches: [CodableMeshBatch]?
  var positions: [Double]?
  var tex0: [Double]?
  var colors: [Int]?
  var influences: [[Double]]?
  var normals: [Double]?
  var indices: [Int]?
}

struct CodableMeshBatch: Codable {
  var indexRange: [Int]?
  var vertexRange: [Int]?
  var usedBones: [Int]?
}
