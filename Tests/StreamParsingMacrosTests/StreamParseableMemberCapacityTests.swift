import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite
  struct `StreamParseableMember capacity tests` {
    @Test
    func `Capacity Requires An Integer Literal`() {
      assertMacro {
        """
        let capacity = 32

        @StreamParseable
        struct Payload {
          @StreamParseableMember(initialCapacity: capacity)
          var values: [Int]
        }
        """
      } diagnostics: {
        """
        let capacity = 32

        @StreamParseable
        struct Payload {
          @StreamParseableMember(initialCapacity: capacity)
          ┬────────────────────────────────────────────────
          ├─ 🛑 @StreamParseableMember(initialCapacity:) requires a nonnegative integer literal.
          ╰─ 🛑 @StreamParseableMember(initialCapacity:) requires a nonnegative integer literal.
          var values: [Int]
        }
        """
      }
    }

    @Test
    func `Capacity Can Only Be Specified Once`() {
      assertMacro {
        """
        @StreamParseable
        struct Payload {
          @StreamParseableMember(initialCapacity: 16)
          @StreamParseableMember(initialCapacity: 32)
          var values: [Int]
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Payload {
          @StreamParseableMember(initialCapacity: 16)
          @StreamParseableMember(initialCapacity: 32)
          ┬──────────────────────────────────────────
          ├─ 🛑 @StreamParseableMember(initialCapacity:) can only be specified once per property.
          ╰─ 🛑 @StreamParseableMember(initialCapacity:) can only be specified once per property.
          var values: [Int]
        }
        """
      }
    }
  }
}
