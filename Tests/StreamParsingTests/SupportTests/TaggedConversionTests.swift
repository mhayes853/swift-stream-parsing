#if StreamParsingTagged
  import CustomDump
  import Tagged
  import Testing

  import StreamParsing
  import StreamParsingCore

  enum UserIDTag {}
  enum EmailTag {}
  enum ActiveTag {}
  enum ProfileTag {}

  @StreamParseable
  struct TaggedProfile: Equatable {
    var city: String = ""
    var zip: Int = 0
  }

  @StreamParseable
  struct TaggedValues: Equatable {
    var id: Tagged<UserIDTag, Int> = 0
    var email: Tagged<EmailTag, String> = ""
    var active: Tagged<ActiveTag, Bool> = false
    var profile: Tagged<ProfileTag, TaggedProfile> = Tagged(rawValue: TaggedProfile())
  }

  @Suite
  struct `Tagged conversion tests` {
    @Test(arguments: [Int.max, 7, 1])
    func `A tagged value accepts whatever its raw value accepts`(chunk: Int) throws {
      var value = TaggedValues.Partial()
      try parsePartial(
        #"{"id":42,"email":"blob@example.com","active":true}"#,
        into: &value,
        chunk: chunk
      )
      expectNoDifference(value.id, 42)
      expectNoDifference(value.email, "blob@example.com")
      expectNoDifference(value.active, true)
    }

    // Tagged has one stored property, so the raw value's schema applies to a pointer to the
    // Tagged itself. This is the case that fails if that ever stops being true.
    @Test(arguments: [Int.max, 7, 1])
    func `A tagged object routes into its raw value`(chunk: Int) throws {
      var value = TaggedValues.Partial()
      try parsePartial(
        #"{"id":1,"profile":{"city":"Brooklyn","zip":11215}}"#,
        into: &value,
        chunk: chunk
      )
      expectNoDifference(value.id, 1)
      expectNoDifference(value.profile?.rawValue.city, "Brooklyn")
      expectNoDifference(value.profile?.rawValue.zip, 11215)
    }

    @Test
    func `A tagged string accumulates across chunks`() throws {
      var value = TaggedValues.Partial()
      try parsePartial(#"{"email":"a\nvery\tlong é€ address"}"#, into: &value, chunk: 1)
      expectNoDifference(value.email, "a\nvery\tlong é€ address")
    }
  }
#endif
