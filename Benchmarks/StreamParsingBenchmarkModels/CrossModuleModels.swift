// `public` copies of in-module benchmark models, parsed from `StreamParsingBenchmarks`, so the rows
// over them price what a library user pays: every generated member sits across a module boundary.
// Field lists must stay identical to the originals in `StreamParsingBenchmarks/Models.swift`.
import StreamParsing

// swiftlint:disable identifier_name

// MARK: - Flat (mirrors `BenchmarkProfile`)

@StreamParseable
public struct CrossModuleProfile {
  public var id: Int = 0
  public var name: String = ""
  public var email: String = ""
  public var age: Int = 0
  public var score: Double = 0
  public var isActive: Bool = false
}

// MARK: - Twitter full (mirrors `BenchmarkTwitterFull`)

@StreamParseable
public struct CrossModuleTwitterFull {
  public var statuses: [CrossModuleTweetFull] = []
}

@StreamParseable
public struct CrossModuleTweetFull {
  public var metadata: CrossModuleTwitterMetadata = CrossModuleTwitterMetadata()
  public var created_at: String = ""
  public var id: Int = 0
  public var id_str: String = ""
  public var text: String = ""
  public var source: String = ""
  public var truncated: Bool = false
  public var in_reply_to_status_id: Int? = nil
  public var in_reply_to_status_id_str: String? = nil
  public var in_reply_to_user_id: Int? = nil
  public var in_reply_to_user_id_str: String? = nil
  public var in_reply_to_screen_name: String? = nil
  public var user: CrossModuleTwitterUserFull = CrossModuleTwitterUserFull()
  public var geo: String? = nil
  public var coordinates: String? = nil
  public var place: String? = nil
  public var contributors: String? = nil
  public var retweet_count: Int = 0
  public var favorite_count: Int = 0
  public var entities: CrossModuleTwitterEntities = CrossModuleTwitterEntities()
  public var favorited: Bool = false
  public var retweeted: Bool = false
  public var possibly_sensitive: Bool? = nil
  public var lang: String = ""
  public var retweeted_status: CrossModuleRetweetedStatusFull? = nil
}

@StreamParseable
public struct CrossModuleRetweetedStatusFull {
  public var metadata: CrossModuleTwitterMetadata = CrossModuleTwitterMetadata()
  public var created_at: String = ""
  public var id: Int = 0
  public var id_str: String = ""
  public var text: String = ""
  public var source: String = ""
  public var truncated: Bool = false
  public var in_reply_to_status_id: Int? = nil
  public var in_reply_to_status_id_str: String? = nil
  public var in_reply_to_user_id: Int? = nil
  public var in_reply_to_user_id_str: String? = nil
  public var in_reply_to_screen_name: String? = nil
  public var user: CrossModuleTwitterUserFull = CrossModuleTwitterUserFull()
  public var geo: String? = nil
  public var coordinates: String? = nil
  public var place: String? = nil
  public var contributors: String? = nil
  public var retweet_count: Int = 0
  public var favorite_count: Int = 0
  public var entities: CrossModuleTwitterEntities = CrossModuleTwitterEntities()
  public var favorited: Bool = false
  public var retweeted: Bool = false
  public var possibly_sensitive: Bool? = nil
  public var lang: String = ""
}

@StreamParseable
public struct CrossModuleTwitterMetadata {
  public var result_type: String = ""
  public var iso_language_code: String = ""
}

@StreamParseable
public struct CrossModuleTwitterUserFull {
  public var id: Int = 0
  public var id_str: String = ""
  public var name: String = ""
  public var screen_name: String = ""
  public var location: String = ""
  public var description: String = ""
  public var url: String? = nil
  public var entities: CrossModuleTwitterUserEntities = CrossModuleTwitterUserEntities()
  public var protected: Bool = false
  public var followers_count: Int = 0
  public var friends_count: Int = 0
  public var listed_count: Int = 0
  public var created_at: String = ""
  public var favourites_count: Int = 0
  public var utc_offset: Int? = nil
  public var time_zone: String? = nil
  public var geo_enabled: Bool = false
  public var verified: Bool = false
  public var statuses_count: Int = 0
  public var lang: String = ""
  public var contributors_enabled: Bool = false
  public var is_translator: Bool = false
  public var is_translation_enabled: Bool = false
  public var profile_background_color: String = ""
  public var profile_background_image_url: String = ""
  public var profile_background_image_url_https: String = ""
  public var profile_background_tile: Bool = false
  public var profile_image_url: String = ""
  public var profile_image_url_https: String = ""
  public var profile_banner_url: String? = nil
  public var profile_link_color: String = ""
  public var profile_sidebar_border_color: String = ""
  public var profile_sidebar_fill_color: String = ""
  public var profile_text_color: String = ""
  public var profile_use_background_image: Bool = false
  public var default_profile: Bool = false
  public var default_profile_image: Bool = false
  public var following: Bool = false
  public var follow_request_sent: Bool = false
  public var notifications: Bool = false
}

@StreamParseable
public struct CrossModuleTwitterUserEntities {
  public var description: CrossModuleTwitterURLList = CrossModuleTwitterURLList()
  public var url: CrossModuleTwitterURLList? = nil
}

@StreamParseable
public struct CrossModuleTwitterURLList {
  public var urls: [CrossModuleTwitterURLEntity] = []
}

@StreamParseable
public struct CrossModuleTwitterURLEntity {
  public var url: String = ""
  public var expanded_url: String = ""
  public var display_url: String = ""
  public var indices: [Int] = []
}

@StreamParseable
public struct CrossModuleTwitterEntities {
  public var hashtags: [CrossModuleTwitterHashtag] = []
  public var symbols: [CrossModuleTwitterHashtag] = []
  public var urls: [CrossModuleTwitterURLEntity] = []
  public var user_mentions: [CrossModuleTwitterUserMention] = []
  public var media: [CrossModuleTwitterMedia] = []
}

@StreamParseable
public struct CrossModuleTwitterHashtag {
  public var text: String = ""
  public var indices: [Int] = []
}

@StreamParseable
public struct CrossModuleTwitterUserMention {
  public var screen_name: String = ""
  public var name: String = ""
  public var id: Int = 0
  public var id_str: String = ""
  public var indices: [Int] = []
}

@StreamParseable
public struct CrossModuleTwitterMedia {
  public var id: Int = 0
  public var id_str: String = ""
  public var indices: [Int] = []
  public var media_url: String = ""
  public var media_url_https: String = ""
  public var url: String = ""
  public var display_url: String = ""
  public var expanded_url: String = ""
  public var type: String = ""
  public var sizes: CrossModuleTwitterMediaSizes = CrossModuleTwitterMediaSizes()
  public var source_status_id: Int? = nil
  public var source_status_id_str: String? = nil
}

@StreamParseable
public struct CrossModuleTwitterMediaSizes {
  public var thumb: CrossModuleTwitterMediaSize = CrossModuleTwitterMediaSize()
  public var small: CrossModuleTwitterMediaSize = CrossModuleTwitterMediaSize()
  public var medium: CrossModuleTwitterMediaSize = CrossModuleTwitterMediaSize()
  public var large: CrossModuleTwitterMediaSize = CrossModuleTwitterMediaSize()
}

@StreamParseable
public struct CrossModuleTwitterMediaSize {
  public var w: Int = 0
  public var h: Int = 0
  public var resize: String = ""
}
