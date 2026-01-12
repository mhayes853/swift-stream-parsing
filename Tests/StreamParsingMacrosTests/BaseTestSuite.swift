import FoundationModels
import MacroTesting
import SnapshotTesting
import StreamParsingMacros
import Testing

@MainActor
@Suite(
  .serialized,
  .macros(
    [
      "StreamParseable": StreamParseableMacro.self,
      "StreamParseableMember": StreamParseableMemberMacro.self
    ],
    record: .failed
  )
) struct BaseTestSuite {}
