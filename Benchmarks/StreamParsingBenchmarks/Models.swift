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

// MARK: - Nested

@StreamParseable
struct BenchmarkAddress: Equatable {
  var street: String = ""
  var city: String = ""
  var postalCode: String = ""
}

@StreamParseable
struct BenchmarkCompany: Equatable {
  var name: String = ""
  var address: BenchmarkAddress = BenchmarkAddress()
}

@StreamParseable
struct BenchmarkEmployee: Equatable {
  var id: Int = 0
  var name: String = ""
  var company: BenchmarkCompany = BenchmarkCompany()
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

@StreamParseable
struct BenchmarkMatrix: Equatable {
  var rows: [[Int]] = []
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

// MARK: - Long strings

@StreamParseable
struct BenchmarkDocument: Equatable {
  var title: String = ""
  var body: String = ""
}
