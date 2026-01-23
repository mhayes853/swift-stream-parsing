# JSON Stream Parser Cache Plan

## Goal
Reduce per-value key path recomputation by caching stable key paths for objects and arrays, while maintaining correct array indexing for append-only parsing.

## Proposed Approach
1) **Precompute stack-indexed key paths during handler registration**
   - Build a lookup table keyed by stack shape (array/object path segments) as handlers are
     registered, so runtime parsing only does a stack lookup instead of key-path assembly.
   - Use stable array element paths (`currentElement`) so array segments are deterministic.
   - Store fully materialized key paths for each handler type (string/bool/number/etc.) per stack key.
   - Sketch of a Swift trie node with unified children:
     ```swift
     private struct PathTrie<Value: StreamParseableValue> {
       struct Paths {
         var string: WritableKeyPath<Value, String>?
         var number: WritableKeyPath<Value, JSONNumberAccumulator>?
         var bool: WritableKeyPath<Value, Bool>?
         var nullable: WritableKeyPath<Value, Void?>?
         var array: WritableKeyPath<Value, any StreamParseableArrayObject>?
         var dictionary: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
       }

       enum Children {
         case none
         case array(PathTrie)
         case object(keys: [String: PathTrie], any: PathTrie?)
       }

       var paths = Paths()
       var children: Children = .none
     }
     ```
   - Sketch of inserting a node (explicit add methods):
     ```swift
     extension PathTrie {
       mutating func addArrayChild() {
         if case .array = children { return }
         children = .array(PathTrie())
       }

       mutating func addObjectChild(for key: String) {
         switch children {
         case .object(var keys, let any):
           if keys[key] == nil { keys[key] = PathTrie() }
           children = .object(keys: keys, any: any)
         default:
           children = .object(keys: [key: PathTrie()], any: nil)
         }
       }

       mutating func addAnyObjectChild() {
         switch children {
         case .object(let keys, nil):
           children = .object(keys: keys, any: PathTrie())
         case .object:
           break
         default:
           children = .object(keys: [:], any: PathTrie())
         }
       }
     }
     ```

1) **Introduce a key-path cache structure in handlers**
   - Add a small cache object owned by the JSON stream handlers that tracks:
      - A stack of key-path components (object keys and array indices).
      - A parallel stack of array element counts (for append-only arrays).
      - A cached, reusable `AnyKeyPath` (or equivalent) for the current container.
   - Pseudocode for registration-time build (inside handlers):
     ```text
     registerScopedHandlers(path):
       merge handler paths into current trie
       if handler has arrayPath:
         at current node: paths.array = appended(path, handler.arrayPath)
       if handler has dictionaryPath:
         at current node: paths.dictionary = appended(path, handler.dictionaryPath)
       if handler has string/bool/number/etc:
         at current node: paths.<type> = appended(path, handler.<type>)

     registerArrayHandler(path):
       let elementHandlers = handlers for Element
       at current node: paths.array = appended(path, \.erasedJSONPath)
       add array child
       in array child node:
         precompute element paths using \.currentElement + elementHandlers
         recursively add children if elementHandlers contains nested arrays/objects

     registerDictionaryHandler(path):
       let valueHandlers = handlers for Value
       at current node: paths.dictionary = appended(path, \.erasedJSONPath)
       add object child (any key)
       in any-object child node:
         precompute value paths using \.[unwrapped: key] for registered keys
         if expectsAnyKey: store a dynamic-key cache hook instead of appending at parse time

     registerKeyedHandler(forKey, path):
       at current node: add object child for key
       in key child node:
         precompute paths by appending handler paths to key path
         recursively build children from nested handlers
     ```

2) **Make array indices stable and derived from counts**
   - On `arrayStart`: push a new array-count (0) and a cached base key path for the array.
   - On `arrayElementStart`: compute index = currentCount, then increment count; set current key path to base + [index].
   - On `arrayEnd`: pop count and cached base key path.

3) **Cache object key paths**
   - On `objectKey`: reuse cached base key path for current object, then append the key path segment for the key.
   - Cache full key paths for frequently used keys if feasible (e.g., small LRU per object level) to reduce string/key-path construction.

4) **Update stack-change flows**
   - Replace recompute-on-stack-change with cache updates driven by parser events (start/end object/array, key read, element start/end).
   - Ensure handler APIs expose hooks to update cache in sync with the parser’s push/pop logic.

5) **Verify correctness and performance**
   - Add tests for nested arrays/objects, mixed containers, and edge cases (empty arrays/objects).
   - Add a micro-benchmark or logging toggle to compare key-path recomputation counts before/after.

## Parser-Time Lookup (Pseudocode)
```text
state:
  trieRoot
  currentNode = trieRoot (position in trie)
  stack = []

onArrayStart:
  push stack: array
  currentNode = currentNode.children.array ?? nil

onArrayEnd:
  pop stack
  currentNode = node for new stack (track a parallel node stack for O(1))

onObjectKey(key):
  push stack: object(key)
  if currentNode.children.object has key:
    currentNode = child for key
  else if currentNode.children.object has any:
    currentNode = any child
  else:
    currentNode = nil

onObjectValueEnd or object key pop:
  pop stack
  currentNode = node for new stack

onValue(type):
  path = currentNode?.paths[type]
  if path != nil: write value via path
```
Note: the parser should treat the trie position as part of its state; stack changes move
`currentNode` (and optionally a parallel node stack) so lookups stay O(1) with no recompute.

## Open Questions
- Where is the best ownership point for the cache (parser vs. handler)?
- Should cached key paths be stored as segments or fully materialized `AnyKeyPath` values?
- Do we want a per-level key cache, or just compute object keys on demand and only cache array indices?
- What should the stack-key representation be (e.g., hashed sequence of `StackElement` kinds/keys)?
- How large can the precomputed lookup get in deeply nested handler graphs?

## Next Step
Inspect current handler and stack logic to identify the exact insertion points for cache updates and to refine the API surface.
