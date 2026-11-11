import StreamParsing

// The `Twitter full` and `LLM message` trees with `partialStrings: .string`: every `String` member
// is a Swift `String` in the partial, and nothing else differs. Generated from `Models.swift` by
// renaming; keep the two in step. Measures what the convenience costs against `StreamString`.

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterFull: Equatable {
  var statuses: [BenchmarkStringStorageTweetFull] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTweetFull: Equatable {
  var metadata: BenchmarkStringStorageTwitterMetadata = BenchmarkStringStorageTwitterMetadata()
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
  var user: BenchmarkStringStorageTwitterUserFull = BenchmarkStringStorageTwitterUserFull()
  var geo: String? = nil
  var coordinates: String? = nil
  var place: String? = nil
  var contributors: String? = nil
  var retweet_count: Int = 0
  var favorite_count: Int = 0
  var entities: BenchmarkStringStorageTwitterEntities = BenchmarkStringStorageTwitterEntities()
  var favorited: Bool = false
  var retweeted: Bool = false
  var possibly_sensitive: Bool? = nil
  var lang: String = ""
  var retweeted_status: BenchmarkStringStorageRetweetedStatusFull? = nil
}

// One level of `retweeted_status` nesting — the corpus never nests a second level, so this omits
// the field itself rather than modeling unbounded recursion nothing in the data exercises.
@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageRetweetedStatusFull: Equatable {
  var metadata: BenchmarkStringStorageTwitterMetadata = BenchmarkStringStorageTwitterMetadata()
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
  var user: BenchmarkStringStorageTwitterUserFull = BenchmarkStringStorageTwitterUserFull()
  var geo: String? = nil
  var coordinates: String? = nil
  var place: String? = nil
  var contributors: String? = nil
  var retweet_count: Int = 0
  var favorite_count: Int = 0
  var entities: BenchmarkStringStorageTwitterEntities = BenchmarkStringStorageTwitterEntities()
  var favorited: Bool = false
  var retweeted: Bool = false
  var possibly_sensitive: Bool? = nil
  var lang: String = ""
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterMetadata: Equatable {
  var result_type: String = ""
  var iso_language_code: String = ""
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterUserFull: Equatable {
  var id: Int = 0
  var id_str: String = ""
  var name: String = ""
  var screen_name: String = ""
  var location: String = ""
  var description: String = ""
  var url: String? = nil
  var entities: BenchmarkStringStorageTwitterUserEntities = BenchmarkStringStorageTwitterUserEntities()
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

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterUserEntities: Equatable {
  var description: BenchmarkStringStorageTwitterURLList = BenchmarkStringStorageTwitterURLList()
  var url: BenchmarkStringStorageTwitterURLList? = nil
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterURLList: Equatable {
  var urls: [BenchmarkStringStorageTwitterURLEntity] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterURLEntity: Equatable {
  var url: String = ""
  var expanded_url: String = ""
  var display_url: String = ""
  var indices: [Int] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterEntities: Equatable {
  var hashtags: [BenchmarkStringStorageTwitterHashtag] = []
  var symbols: [BenchmarkStringStorageTwitterHashtag] = []
  var urls: [BenchmarkStringStorageTwitterURLEntity] = []
  var user_mentions: [BenchmarkStringStorageTwitterUserMention] = []
  var media: [BenchmarkStringStorageTwitterMedia] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterHashtag: Equatable {
  var text: String = ""
  var indices: [Int] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterUserMention: Equatable {
  var screen_name: String = ""
  var name: String = ""
  var id: Int = 0
  var id_str: String = ""
  var indices: [Int] = []
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterMedia: Equatable {
  var id: Int = 0
  var id_str: String = ""
  var indices: [Int] = []
  var media_url: String = ""
  var media_url_https: String = ""
  var url: String = ""
  var display_url: String = ""
  var expanded_url: String = ""
  var type: String = ""
  var sizes: BenchmarkStringStorageTwitterMediaSizes = BenchmarkStringStorageTwitterMediaSizes()
  var source_status_id: Int? = nil
  var source_status_id_str: String? = nil
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterMediaSizes: Equatable {
  var thumb: BenchmarkStringStorageTwitterMediaSize = BenchmarkStringStorageTwitterMediaSize()
  var small: BenchmarkStringStorageTwitterMediaSize = BenchmarkStringStorageTwitterMediaSize()
  var medium: BenchmarkStringStorageTwitterMediaSize = BenchmarkStringStorageTwitterMediaSize()
  var large: BenchmarkStringStorageTwitterMediaSize = BenchmarkStringStorageTwitterMediaSize()
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageTwitterMediaSize: Equatable {
  var w: Int = 0
  var h: Int = 0
  var resize: String = ""
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageLLMMessage: Equatable {
  var id: String = ""
  var role: String = ""
  var model: String = ""
  var content: [BenchmarkStringStorageContentBlock] = []
  var stop_reason: String = ""
  var usage: BenchmarkUsage = BenchmarkUsage()
}

@StreamParseable(partialStrings: .string)
struct BenchmarkStringStorageContentBlock: Equatable {
  var type: String = ""
  var text: String = ""
  var name: String = ""
}
