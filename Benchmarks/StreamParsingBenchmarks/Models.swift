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

@StreamParseable
struct BenchmarkTwitterUserMatched: Equatable {
  var name: String = ""
  var screen_name: String = ""
  var followers_count: Int = 0
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

// MARK: - Long strings

@StreamParseable
struct BenchmarkDocument: Equatable {
  var title: String = ""
  var body: String = ""
}
