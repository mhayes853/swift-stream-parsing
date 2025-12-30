// import MacroTesting
// import Testing

// extension BaseTestSuite {
//   @Suite
//   struct `StreamParseableMacro tests` {
//     @Test
//     func `Basic`() {
//       assertMacro {
//         """
//         @StreamParseable
//         struct Person {
//           var name: String
//           var age: Int
//         }
//         """
//       } expansion: {
//         """
//         struct Person {
//           var name: String
//           var age: Int
//         }

//         extension Person: StreamParsingCore.StreamParseable {
//           struct Partial: StreamParsingCore.StreamPartial {
//             var name: String.Partial?
//             var age: Int.Partial?

//             init() {}

//             mutating func reduce(action: DefaultStreamAction) throws {
//               switch action {
//               case .delegateKeyed("name", let action):
//                 try _streamParsingPerformReduce(&self.name, action)
//               case .delegateKeyed("age", let action):
//                 try _streamParsingPerformReduce(&self.age, action)
//               default:
//                 throw StreamParseableError.unsupportedAction(action)
//               }
//             }
//           }
//         }
//         """
//       }
//     }

//   }
// }
