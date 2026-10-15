# GraphRAG — Graph-based Retrieval Augmented Generation

> ⚠️ **Theory and rationale, not a description of what's built.** Most of this document (Microsoft's research, generic Neo4j/LangChain/LlamaIndex examples, the SQLite schema sketch in §7) is background on GraphRAG as a general technique — it does not describe UNIUN's actual implementation. UNIUN doesn't use SQLite, community detection, or LLM-based entity extraction for its graph; the real implementation is Isar-based (`GraphNodeModel`/`GraphEdgeModel`/`MemoryNodeModel`, vector-seed → 1-hop BFS expansion), documented in `docs/SHIVA/SHIV_AI.md`'s RAG Pipeline section. Read this doc for *why* graph-augmented retrieval is worth doing at all; read `SHIV_AI.md` for what actually runs on-device.

This document covers GraphRAG deeply: what it is, how it works, why it is better than
standard vector RAG for certain queries, Microsoft's research findings, and how to
implement a lightweight version on mobile using the knowledge graph that UNIUN already
builds (notes referencing each other, tags connecting notes, users following users).

The existing `rag.md` explains standard vector RAG. Read that first.

---

## 1. What Is GraphRAG — And How Does It Differ From Standard RAG?

Standard RAG (vector RAG) converts text into dense numerical vectors (embeddings) and
retrieves the chunks that are closest in vector space to the user's query. It answers
the question "what text is semantically similar to this query?".

GraphRAG replaces or augments that flat similarity search with a **knowledge graph**:
a structure of entities (nodes) connected by typed relationships (edges). Retrieval
becomes graph traversal — following the links between concepts, people, tags, and
events — rather than floating-point distance calculations.

### Side-by-Side Comparison

| Dimension              | Standard (Vector) RAG                     | GraphRAG                                          |
|------------------------|-------------------------------------------|---------------------------------------------------|
| Data representation    | Isolated text chunks → embedding vectors  | Entities and relationships → nodes and edges      |
| Retrieval mechanism    | Cosine / inner-product similarity search  | Graph traversal + optional vector scoring         |
| Multi-hop reasoning    | Poor — chunk A and chunk C retrieved, but the linking chunk B is often missed | Strong — explicit edges encode the A → B → C path |
| Global questions       | Fails — can only pull a few chunks, misses big-picture themes | Strong — community summaries cover entire dataset  |
| Entity disambiguation  | Weak — two mentions of "Alex" get averaged | Strong — each entity is a distinct node with context |
| Explainability         | Black-box similarity score                | Traceable path through graph                      |
| Hallucination risk     | Higher — LLM stitches unrelated chunks    | Lower — LLM follows verified edges                |
| Setup cost             | Low — just embed and store                | Higher — must extract entities and build graph    |
| Query latency          | Fast (ANN index lookup)                   | Slower (graph traversal, community scoring)       |

### The Core Limitation Standard RAG Cannot Solve

Vector RAG works by retrieving isolated fragments. It answers questions that live
inside a single chunk. It fails on:

1. **Multi-hop questions**: "Which notes reference a concept that is also tagged
   #philosophy?" — requires crossing two edges in the graph.
2. **Global sensemaking questions**: "What are the main themes across all my notes?"
   — requires synthesizing the entire corpus, not just top-K similar chunks.
3. **Relationship questions**: "How are my notes on Nostr and my notes on Bitcoin
   connected?" — requires following the referential graph.

GraphRAG was designed specifically for these failure modes.

---

## 2. How a Knowledge Graph Enhances RAG Retrieval

A knowledge graph stores information as **triples**: (subject, predicate, object).
For example:
- (Note_A, references, Note_B)
- (Note_B, tagged_with, #Bitcoin)
- (User_X, follows, User_Y)
- (Note_C, authored_by, User_Y)

When a user asks a question, the retrieval pipeline:

1. Maps the query to one or more **seed entities** (nodes in the graph).
2. **Traverses edges** outward from those seeds — collecting neighboring nodes,
   their text content, and the relationship types that connect them.
3. Optionally applies **community detection** to identify thematically related
   clusters of notes, even if no direct edge connects them.
4. **Verbalizes** the retrieved subgraph into natural language that can be injected
   into the LLM prompt.

The key insight: instead of retrieving flat text chunks, you retrieve a **connected
subgraph** — a mini-network of related entities with their relationships made
explicit. The LLM receives not just content but *structure*: "Note A references
Note B, which is tagged #Nostr, which is also referenced by three other notes you
saved last week."

### Why This Reduces Hallucinations

Standard RAG gives the LLM disconnected fragments; the LLM must infer how they
connect. It often infers incorrectly. GraphRAG gives the LLM the actual edges —
verified connections that exist in the data. The LLM follows paths rather than
inventing them.

### Why This Enables Multi-Hop Reasoning

A multi-hop query like "find notes about topics I follow from users I follow" requires:
- Hop 1: current_user → follows → followed_users
- Hop 2: followed_users → authored → their_notes
- Hop 3: their_notes → tagged_with → tags
- Hop 4: tags → connects → notes_in_my_graph

Vector similarity alone cannot execute this chain. Graph traversal can — it is
literally the traversal path above.

---

## 3. How GraphRAG Works Technically — Full Pipeline

GraphRAG has two phases: **indexing** (offline, happens when data changes) and
**querying** (online, happens when the user asks something).

### Phase 1: Indexing Pipeline

```
Raw text (notes, documents)
        |
        v
[Step 1] Chunking
  - Split text into 600-token chunks with 100-token overlaps
  - Overlap prevents information loss at chunk boundaries

        |
        v
[Step 2] Entity & Relationship Extraction  (LLM-powered)
  - LLM reads each chunk and outputs triples:
    Entity1 --> Relationship --> Entity2 [strength: 0.0-1.0]
  - Examples: "Satoshi --> created --> Bitcoin [strength: 0.95]"
  - Few-shot prompting gives the LLM examples of "good" extractions
  - Two-step approach works best:
      (a) Extract entities first (structured output, e.g. JSON list)
      (b) Then extract relationships between those entities
  - De-duplicate: merge mentions of the same entity across chunks

        |
        v
[Step 3] Knowledge Graph Construction
  - Store entities as nodes with properties (type, description, source chunks)
  - Store relationships as weighted, typed edges
  - Maintain links back to source chunks for traceability
  - Index: create full-text indexes on entity names for fast lookup

        |
        v
[Step 4] Community Detection (Leiden algorithm)
  - Partition the graph into clusters of densely connected nodes
  - Leiden is preferred over Louvain: it guarantees well-connected communities
    and is faster on large graphs
  - Result: a hierarchy of communities (level 0 = broad, level N = fine-grained)
  - Each community = a "theme" in the corpus

        |
        v
[Step 5] Community Summary Generation  (LLM-powered)
  - For each community, LLM generates a short summary of that cluster's theme
  - These summaries are stored alongside the community membership
  - Higher-degree nodes (more connections) are prioritized for summarization
  - At the root level, this creates a "table of contents" for the entire corpus
```

The community summaries are the key innovation. They let GraphRAG answer global
questions ("what are the themes in my notes?") without reading every note — the
summaries are pre-computed indexes into the thematic structure.

### Phase 2: Query Pipeline

GraphRAG supports two distinct query modes, each optimized for different question types.

#### Local Query (Entity-Centric)

Best for: "Tell me about [specific entity]", "What do my notes say about Bitcoin?"

```
User query: "What do my notes say about Bitcoin?"
        |
        v
[Step 1] Entity Identification
  - Extract key entities from the query ("Bitcoin")
  - Look them up in the graph's full-text index

        |
        v
[Step 2] Neighborhood Retrieval
  - From the seed node (Bitcoin), traverse outward k hops
  - Collect all neighboring nodes, edge types, and their text
  - Apply degree centrality: higher-connected nodes are more important
  - Collect related community summaries for context

        |
        v
[Step 3] Context Assembly
  - Verbalize the retrieved subgraph into readable text
  - Include: entity descriptions, relationship sentences, source note snippets
  - Rank and filter to fit the LLM's context window

        |
        v
[Step 4] LLM Generation
  - Inject assembled context into prompt
  - LLM answers grounded in the specific subgraph retrieved
```

#### Global Query (Corpus-Wide)

Best for: "What are my main interests?", "Summarize what I've been learning lately."

```
User query: "What are my main interests based on my notes?"
        |
        v
[Step 1] Community Relevance Scoring  (Map phase)
  - For each community summary, ask LLM: "Is this relevant to the query? Score 0-10"
  - Use a small/cheap model for this rating step
  - Discard communities scoring 0 (not relevant)
  - Dynamic community selection (Microsoft's 2024 improvement):
      start at root communities, traverse down only if relevant,
      prune entire branches if root-level summary is irrelevant
      → 77% cost reduction vs. evaluating all communities

        |
        v
[Step 2] Answer Synthesis  (Reduce phase)
  - Sort surviving communities by relevance score (highest first)
  - Iteratively add community summaries to context until token limit reached
  - LLM generates a final answer from this ranked, filtered set of summaries

        |
        v
[Step 3] LLM Generation
  - LLM produces a comprehensive, thematic answer
  - Covers the entire corpus, not just a few similar chunks
```

### The Verbalization Step

Graphs cannot be directly passed to LLMs. The retrieved subgraph must be converted
to natural language. A simple verbalization of a triple:

```
Triple: (Note_A, references, Note_B)
Verbalized: "Your note 'Note A' references 'Note B'."

Triple: (Note_B, tagged_with, #Philosophy)
Verbalized: "Note B is tagged with #Philosophy."

Combined subgraph context injected into prompt:
"Your note 'Introduction to Stoicism' (saved 3 days ago) references
'Marcus Aurelius Quotes', which is tagged #Philosophy and #Stoicism.
Three other notes you saved also reference 'Marcus Aurelius Quotes'."
```

This gives the LLM a dense, relationship-aware context — far more informative than
three independent text chunks.

---

## 4. Advantages Over Standard Vector Similarity RAG

### 4a. Multi-Hop Reasoning

**Standard RAG fails**: retrieves chunk A and chunk C, misses the connecting chunk B.
GraphRAG stores B as an explicit edge. Multi-hop traversal is O(hops × branching_factor)
not O(N) scan.

Research finding (arxiv 2502.11371): GraphRAG achieves 64.60% F1 on HotPotQA
(multi-hop benchmark) vs. standard RAG's weakness on the same benchmark. Approximately
13.6% of queries are *only* solvable by GraphRAG vs. 11.6% solvable only by standard RAG.

### 4b. Global Sensemaking

Standard RAG can only retrieve top-K chunks (typically 3-10). For a question that
requires synthesizing 1,000 notes, top-K retrieval gives a biased, incomplete picture.

GraphRAG pre-computes community summaries that compress entire thematic clusters.
The root-level summaries require **97% fewer context tokens** than reading all source
text, while covering the entire corpus thematically.

Microsoft's original GraphRAG paper found:
- 72–83% win rate on comprehensiveness against baseline RAG (podcast transcripts)
- 75–82% win rate on diversity of answers
- These results were statistically significant (p < .001)

### 4c. Reduced Hallucinations

Because the LLM follows explicit, verified edges rather than inferring connections
from semantically similar fragments, it is less likely to confabulate relationships
that do not exist. The graph structure acts as a constraint on what connections the
LLM can claim.

### 4d. Token Efficiency

GraphRAG can provide richer context in fewer tokens: structured relationship sentences
are denser than raw note content. Research shows "26% to 97% fewer tokens" needed
for LLM responses when using graph-structured context vs. raw chunk injection.

### 4e. Structural Explainability

Every answer can be traced back to specific nodes and edges. You can show the user
"This answer was based on Note A → references → Note B → tagged #Bitcoin."
Standard RAG can only say "this was based on chunks X, Y, Z."

### 4f. Where Standard RAG Is Still Better

- **Single-hop, direct factual questions**: "What did I write about relays?" — vector
  similarity is faster and sufficient.
- **Dense prose retrieval**: when the relevant content is in a single chunk and does
  not require relationship traversal.
- **Cold start**: before the graph has enough edges to be useful, vector search gives
  better results with less setup.

Strategic recommendation (arxiv 2502.11371): route fact-based direct queries to
standard RAG; route multi-hop and thematic queries to GraphRAG. Combining both
achieves the highest accuracy at the cost of latency.

---

## 5. UNIUN's Knowledge Graph as a GraphRAG Knowledge Graph

UNIUN already builds a knowledge graph through normal user activity. Every feature
maps directly to a graph primitive.

### Existing Graph Primitives in UNIUN

```
NODES:
  Note          → every note is an entity
  Tag           → every tag is an entity
  User          → every user (pubkey) is an entity
  Topic/Concept → entities extracted from note content

EDGES:
  Note  --[references]-->    Note          (e-tag in Nostr event)
  Note  --[tagged_with]-->   Tag           (t-tag in Nostr event)
  Note  --[authored_by]-->   User          (pubkey field)
  User  --[follows]-->       User          (NIP-02 contact list)
  Note  --[saved_by]-->      User          (local save action)
  Note  --[contains]-->      Topic         (extracted entity)
  Tag   --[co_occurs_with]--> Tag          (two tags on same note)
  Note  --[replied_to]-->    Note          (reply e-tag)
```

This is a rich, heterogeneous graph — the same type of graph used in production
GraphRAG systems for social and document corpora.

### Traversal Patterns for Different Query Types

**"What do my saved notes say about a topic?"** (Local query)
```
seed: query → embedded → find closest Tag or Topic node
traverse: Tag/Topic → [tagged_with]← → Notes → content
expand: Notes → [references]→ → referenced Notes → content
result: a connected cluster of notes + their relationships
```

**"What are my main interests?"** (Global query)
```
use pre-computed community summaries over the full note graph
community detection groups: {#Bitcoin, #Nostr, #Cryptography}
                             {#Philosophy, #Stoicism, #Books}
                             {#Engineering, #Flutter, #Dart}
LLM synthesizes from community summaries, not individual notes
```

**"What are people I follow writing about?"** (Multi-hop social query)
```
hop 1: current_user → [follows] → followed_users
hop 2: followed_users ← [authored_by] ← their_notes
hop 3: their_notes → [tagged_with] → tags
result: thematic map of followed users' content
```

**"Find notes related to this note I'm reading"** (Graph neighborhood query)
```
seed: current_note node
traverse 1-hop: notes it references, notes that reference it, its tags
traverse 2-hop: notes sharing the same tags, notes referenced by referenced notes
result: the note's knowledge neighborhood
```

**"What did I save this week that connects to something I saved 6 months ago?"**
(Temporal + relational)
```
filter nodes by timestamp (this week's notes)
check if any share tag nodes or topic nodes with older saved notes
return bridging paths
```

### Graph-Enhanced Prompt Template for UNIUN

```dart
// GraphRAG prompt for UNIUN (Shiv AI assistant)
String buildGraphRAGPrompt({
  required String userQuery,
  required List<GraphNode> seedNotes,
  required List<GraphEdge> retrievedEdges,
  required List<String> communitySummaries,
}) {
  final relationshipContext = retrievedEdges
      .map((e) => '- "${e.sourceTitle}" ${e.relationship} "${e.targetTitle}"')
      .join('\n');

  final noteContents = seedNotes
      .map((n) => 'Note: ${n.title}\n${n.content}')
      .join('\n\n');

  final themes = communitySummaries.isNotEmpty
      ? 'Thematic context:\n${communitySummaries.join("\n")}\n\n'
      : '';

  return '''
You are Shiv, a personal knowledge assistant for UNIUN.

$themes
Relationships between the user's notes:
$relationshipContext

Relevant note content:
$noteContents

User question: $userQuery

Answer based strictly on the notes and relationships above:
''';
}
```

---

## 6. Microsoft's GraphRAG Paper — Key Findings

**Paper**: "From Local to Global: A Graph RAG Approach to Query-Focused Summarization"
(Edge et al., Microsoft Research, April 2024, arxiv 2404.16130)

### The Core Problem the Paper Addresses

Conventional RAG fails on **sensemaking queries** — questions that require reasoning
over an entire dataset rather than retrieving specific facts. Example: "What are
the main themes in these 500 news articles?" Standard RAG can only retrieve the 5
most similar chunks; it cannot reason over the full corpus.

The paper formalizes this as **Query-Focused Summarization (QFS)** at corpus scale,
and demonstrates that GraphRAG substantially outperforms baseline RAG on QFS tasks.

### The Indexing Pipeline (What They Built)

1. **Text chunking**: 600-token chunks, 100-token overlap.
2. **Entity/relationship extraction**: LLM prompted with few-shot examples to output
   triples. Domain-tailored examples (e.g., different prompts for news vs. scientific
   text) improve extraction quality.
3. **Knowledge graph construction**: entities deduped and aggregated across chunks.
   Test datasets produced graphs of 8,564–15,754 nodes.
4. **Hierarchical community detection**: Leiden algorithm applied. The paper chose
   Leiden over Louvain because Leiden guarantees every community is internally
   well-connected (Louvain can produce internally disconnected communities).
   The result is a multi-level hierarchy where each level is a mutually exclusive,
   collectively exhaustive partition of the graph.
5. **Community summary generation**: LLM generates summaries for each community,
   prioritizing high-degree (highly connected) nodes in the prompt. Summaries
   are stored at every level of the hierarchy.

### Local vs. Global Query Modes

**Local search**: best for questions about specific entities, people, events.
   - Retrieves the entity's neighborhood: connected nodes, relationships, and the
     community summary of the cluster it belongs to.
   - Provides precise, entity-specific answers with traceable sources.

**Global search**: best for holistic, corpus-wide questions.
   - Collects community summaries from all communities.
   - Map phase: LLM rates each summary's relevance to the query (0–10 scale).
   - Reduce phase: summaries ranked by score, top summaries fed to LLM for
     final synthesis.
   - This map-reduce architecture is embarrassingly parallelizable.

### Evaluation Results

Two datasets tested: podcast transcripts (1 million tokens) and news articles (1 million tokens).

**Comprehensiveness** (does the answer cover all relevant aspects?):
- GraphRAG C0 (root-level communities): 72% win rate on podcasts, 72% on news
- GraphRAG C1 (fine-grained communities): 83% win rate on podcasts, 80% on news
- Both statistically significant (p < 0.001)

**Diversity** (does the answer present multiple perspectives?):
- GraphRAG C0: 75% win rate on podcasts, 62% on news
- GraphRAG C1: 82% win rate on podcasts, 71% on news

**Directness** (is the answer concise?):
- Baseline vector RAG wins on directness — shorter answers.
- This is expected: global graph answers are intentionally comprehensive.

**Token efficiency**:
- Root-level community summaries use **97% fewer tokens** than source-text summarization,
  while achieving comparable comprehensiveness.

### The Dynamic Community Selection Improvement (2024)

Microsoft published a follow-up improvement: instead of evaluating all community
summaries at a fixed hierarchy level, use dynamic selection:

- Start at root-level communities.
- Rate each root summary for relevance.
- If relevant: descend to child communities for finer-grained retrieval.
- If irrelevant: prune the entire subtree (skip all children).

**Result**:
- 77% reduction in token cost vs. static level-1 search.
- Processes ~470 community reports instead of ~1,500.
- Comparable answer quality.
- Uses GPT-4o-mini for relevance rating (cheap), GPT-4o only for final synthesis.

---

## 7. Implementing Lightweight GraphRAG on Mobile (No Heavy Infrastructure)

The full Microsoft GraphRAG stack requires LLM API calls for entity extraction,
Neo4j for graph storage, and significant compute for community detection. None of
that is feasible on a mobile device with a 2B parameter local model.

The mobile approach uses a **pre-built graph** (UNIUN builds it naturally through
user activity) and **lightweight traversal** instead of expensive LLM-based extraction.

### What UNIUN Does Not Need to Implement

- LLM-based entity extraction from raw text (the graph already exists via Nostr
  e-tags, t-tags, and follow lists — these ARE the entities and edges)
- Graph database (Isar/SQLite is sufficient for the graph sizes UNIUN will encounter)
- Community detection at query time (run offline, cache results, update on major
  graph changes)

### SQLite Schema for the Graph

```sql
-- Nodes
CREATE TABLE graph_nodes (
  id          TEXT PRIMARY KEY,   -- note id, pubkey, or tag name
  node_type   TEXT NOT NULL,      -- 'note', 'user', 'tag', 'topic'
  label       TEXT,               -- human-readable name
  content     TEXT,               -- text content (for notes)
  embedding   BLOB,               -- pre-computed embedding vector (for notes)
  created_at  INTEGER,
  metadata    TEXT                -- JSON blob for extra properties
);

-- Edges
CREATE TABLE graph_edges (
  source_id    TEXT NOT NULL,
  target_id    TEXT NOT NULL,
  edge_type    TEXT NOT NULL,     -- 'references', 'tagged_with', 'authored_by',
                                  -- 'follows', 'saved_by', 'replied_to'
  weight       REAL DEFAULT 1.0,  -- co-occurrence count or explicit weight
  created_at   INTEGER,
  PRIMARY KEY (source_id, target_id, edge_type),
  FOREIGN KEY (source_id) REFERENCES graph_nodes(id),
  FOREIGN KEY (target_id) REFERENCES graph_nodes(id)
);

CREATE INDEX idx_edges_source ON graph_edges(source_id);
CREATE INDEX idx_edges_target ON graph_edges(target_id);
CREATE INDEX idx_nodes_type   ON graph_nodes(node_type);
```

### Community Detection (Offline, Lightweight)

For UNIUN's graph sizes (<5,000 nodes for personal use), a simple approach works:

**Option A: Connected Components + Tag Clustering** (no external library needed)
```dart
// Group notes by shared tags — notes sharing ≥2 tags are in the same community
// This is O(N * T) where T = average tags per note, fast enough on-device
Map<String, List<String>> tagToCommunity(List<NoteModel> notes) {
  final tagIndex = <String, Set<String>>{};  // tag → set of note IDs
  for (final note in notes) {
    for (final tag in note.tags) {
      tagIndex.putIfAbsent(tag, () => {}).add(note.id);
    }
  }
  // Union-Find to merge notes sharing tags
  // Result: community_id → [note_ids]
}
```

**Option B: Louvain via a lightweight Dart port** (for slightly larger graphs)
The Louvain algorithm is simpler to implement than Leiden and sufficient for graphs
<50,000 nodes. A Dart implementation requires only adjacency list data structures.

**Option C: Degree-centrality communities** (simplest, good enough for notes)
```sql
-- Find highly connected "hub" notes (likely the important ones)
SELECT source_id, COUNT(*) as degree
FROM graph_edges
GROUP BY source_id
ORDER BY degree DESC
LIMIT 20;
```
Hub notes approximate community centers. Notes within 2 hops of a hub form an
informal community.

**When to run community detection**:
- On first app launch after a significant sync (>50 new notes)
- In a background isolate (Dart `Isolate.spawn`)
- Cache results in a `communities` table until the next major sync
- Store: community_id, member_note_ids, pre-generated summary text

### Community Summary Generation (On-Device with Gemma 2B)

Instead of calling GPT-4 for community summaries, use Gemma 2B locally:

```dart
// Build a community summary with on-device Gemma 2B
Future<String> generateCommunitySummary({
  required List<NoteModel> communityNotes,
  required FlutterEdgeAiModel model,
}) async {
  // Take the top 5 most-connected notes from this community
  final topNotes = communityNotes
      .sortedByDescending((n) => n.graphDegree)
      .take(5);

  final noteTitles = topNotes
      .map((n) => '- ${n.content.substring(0, min(100, n.content.length))}')
      .join('\n');

  final prompt = '''
The following notes are thematically related:
$noteTitles

In one sentence, what is the common theme of these notes?
Theme:''';

  final chat = await model.createChat(maxTokens: 128);
  await chat.addQueryChunk(Message.text(text: prompt, isUser: true));

  final buffer = StringBuffer();
  await for (final response in chat.generateChatResponseAsync()) {
    if (response is TextResponse) buffer.write(response.token);
  }
  await chat.close();
  return buffer.toString().trim();
}
```

### Graph Traversal for Context Retrieval (Query Time)

```dart
// Retrieve graph context for a user query
Future<GraphContext> retrieveGraphContext({
  required String userQuery,
  required List<double> queryEmbedding,
  required Database db,
  int hops = 2,
  int maxNodes = 20,
}) async {
  // Step 1: Find seed nodes via vector similarity on note embeddings
  final seedNoteIds = await findSimilarNotes(queryEmbedding, db, topK: 3);

  // Step 2: BFS/DFS traversal from seed nodes
  final visited = <String>{};
  final queue = Queue<String>();
  final retrievedNodes = <GraphNode>[];
  final retrievedEdges = <GraphEdge>[];

  queue.addAll(seedNoteIds);
  visited.addAll(seedNoteIds);

  int currentHop = 0;
  while (queue.isNotEmpty && currentHop < hops) {
    final batchSize = queue.length;
    for (int i = 0; i < batchSize; i++) {
      final nodeId = queue.removeFirst();

      // Fetch node content
      final node = await db.query('graph_nodes',
          where: 'id = ?', whereArgs: [nodeId]);
      if (node.isNotEmpty) retrievedNodes.add(GraphNode.fromRow(node.first));

      // Fetch all edges from this node
      final edges = await db.query('graph_edges',
          where: 'source_id = ? OR target_id = ?',
          whereArgs: [nodeId, nodeId]);

      for (final edge in edges) {
        retrievedEdges.add(GraphEdge.fromRow(edge));
        final neighborId = edge['source_id'] == nodeId
            ? edge['target_id'] as String
            : edge['source_id'] as String;

        if (!visited.contains(neighborId) &&
            retrievedNodes.length < maxNodes) {
          visited.add(neighborId);
          queue.add(neighborId);
        }
      }
    }
    currentHop++;
  }

  // Step 3: Find which communities the seed notes belong to
  final communityIds = await getCommunitiesForNotes(seedNoteIds, db);
  final communitySummaries = await getCommunitySummaries(communityIds, db);

  return GraphContext(
    nodes: retrievedNodes,
    edges: retrievedEdges,
    communitySummaries: communitySummaries,
  );
}
```

### Degree Centrality for Node Importance Ranking

Not all retrieved nodes are equally important. Rank them by degree centrality
(number of connections) to prioritize the most important ones when building the
LLM prompt:

```dart
// Sort retrieved nodes by their degree in the full graph
// (pre-computed and stored in graph_nodes.metadata)
List<GraphNode> rankByDegree(List<GraphNode> nodes) {
  return nodes.sortedByDescending((n) => n.degree);
}
```

### Assembling the Final LLM Prompt

```dart
String assembleGraphRAGPrompt({
  required String userQuery,
  required GraphContext context,
  int maxContextTokens = 800,  // Gemma 2B has 1024 token limit; leave room for response
}) {
  final buffer = StringBuffer();

  // Add community summaries first (thematic overview)
  if (context.communitySummaries.isNotEmpty) {
    buffer.writeln('Thematic context from your notes:');
    for (final summary in context.communitySummaries.take(3)) {
      buffer.writeln('- $summary');
    }
    buffer.writeln();
  }

  // Add relationship sentences
  if (context.edges.isNotEmpty) {
    buffer.writeln('Connections between your notes:');
    for (final edge in context.edges.take(10)) {
      buffer.writeln('- "${edge.sourceLabel}" ${_edgeTypeToText(edge.edgeType)} "${edge.targetLabel}"');
    }
    buffer.writeln();
  }

  // Add note content (most important nodes first, by degree)
  buffer.writeln('Relevant notes:');
  final rankedNodes = rankByDegree(context.nodes)
      .where((n) => n.nodeType == 'note')
      .take(5);
  for (final node in rankedNodes) {
    final snippet = node.content.substring(0, min(200, node.content.length));
    buffer.writeln('Note: $snippet');
    buffer.writeln();
  }

  buffer.writeln('Question: $userQuery');
  buffer.writeln('Answer based only on the notes and connections above:');

  return buffer.toString();
}

String _edgeTypeToText(String edgeType) {
  return switch (edgeType) {
    'references'   => 'references',
    'tagged_with'  => 'is tagged with',
    'replied_to'   => 'is a reply to',
    'authored_by'  => 'was written by',
    'follows'      => 'follows',
    _              => edgeType,
  };
}
```

### Full Mobile GraphRAG Flow

```
USER QUERY
    |
    v
[1] Embed query → query_vector (EmbeddingGemma 300M on-device, ~200MB)
    |
    v
[2] Find seed notes via cosine similarity on stored note embeddings
    (in-memory for <1000 notes, SQLite HNSW for larger)
    |
    v
[3] Graph traversal (BFS, 2 hops) from seed note nodes
    → collect neighboring notes, tags, users via SQLite edge table
    → returns: list of nodes, list of edges
    |
    v
[4] Look up community memberships for seed notes
    → fetch pre-computed community summaries from cache
    |
    v
[5] Rank nodes by degree centrality
    → top 5 notes + top 10 relationships + top 3 community summaries
    |
    v
[6] Verbalize subgraph → natural language context string
    |
    v
[7] Assemble prompt: [system] + [graph context] + [note content] + [question]
    |
    v
[8] Gemma 2B (flutter_edge_ai) generates answer
    → streams tokens via generateChatResponseAsync()
    |
    v
[9] ShivStreamingText renders token-by-token
```

### Performance Expectations on Mobile

| Operation                          | Estimated time        |
|------------------------------------|-----------------------|
| Embedding query (EmbeddingGemma)   | ~50–100ms             |
| Cosine similarity, 1000 notes      | ~10ms (Dart, in-memory)|
| SQLite graph traversal, 2 hops     | ~20–50ms              |
| Community summary lookup           | ~5ms (cached)         |
| Prompt assembly                    | ~1ms                  |
| Gemma 2B first token               | ~500ms–2s (GPU)       |
| Gemma 2B full response (100 tokens)| ~3–8s (GPU)           |

The graph operations add ~75–150ms to retrieval. This is acceptable. The LLM
inference dominates latency regardless.

### When to Use Standard RAG vs. GraphRAG (Decision Logic for Shiv)

```dart
QueryMode selectQueryMode(String userQuery) {
  // Global/thematic queries → GraphRAG global mode
  final globalIndicators = [
    'main themes', 'interests', 'patterns', 'what have i been',
    'summarize everything', 'overview', 'in general', 'lately',
  ];
  if (globalIndicators.any((kw) => userQuery.toLowerCase().contains(kw))) {
    return QueryMode.graphGlobal;
  }

  // Multi-hop / relational queries → GraphRAG local mode
  final multiHopIndicators = [
    'connected', 'related to', 'references', 'links to',
    'people i follow', 'who also', 'same tag', 'similar to',
  ];
  if (multiHopIndicators.any((kw) => userQuery.toLowerCase().contains(kw))) {
    return QueryMode.graphLocal;
  }

  // Direct factual / single-hop → standard vector RAG (faster, sufficient)
  return QueryMode.vectorRAG;
}
```

---

## 8. Neo4j and LangChain GraphRAG — Reference Implementations

These are production-grade server-side implementations. UNIUN does not use these
directly, but the patterns inform the mobile design.

### Neo4j + LangChain Pattern

Neo4j stores both vectors (for similarity) and graph structure (for traversal) in
one database. LangChain orchestrates the two retrieval modes.

**Graph construction with LLMGraphTransformer:**
```python
from langchain_experimental.graph_transformers import LLMGraphTransformer
from langchain_openai import ChatOpenAI

llm_transformer = LLMGraphTransformer(llm=ChatOpenAI(model_name="gpt-4"))
graph_documents = llm_transformer.convert_to_graph_documents(documents)
# Each GraphDocument has: nodes (entities), relationships (edges), source document
graph.add_graph_documents(
    graph_documents,
    baseEntityLabel=True,   # adds __Entity__ label for indexing
    include_source=True     # maintains link back to source chunk
)
```

**Hybrid retrieval (vector + graph):**
```python
# Vector search for semantic similarity
vector_index = Neo4jVector.from_existing_graph(
    OpenAIEmbeddings(),
    search_type="hybrid",   # combines vector + keyword (BM25)
    node_label="Document",
    text_node_properties=["text"]
)

# Entity extraction from query
class Entities(BaseModel):
    names: List[str] = Field(..., description="Entities in the query")

entity_chain = prompt | llm.with_structured_output(Entities)

# Graph neighborhood query (Cypher)
cypher_query = """
CALL db.index.fulltext.queryNodes('entity', $query, {limit: 2})
YIELD node, score
MATCH (node)-[r]-(neighbor)
RETURN node.id, type(r), neighbor.id
LIMIT 50
"""
```

**Full RAG chain combining both:**
```python
chain = RunnableParallel({
    "vector_context": query | vector_retriever,
    "graph_context":  query | entity_chain | cypher_retriever,
    "question":       RunnablePassthrough()
}) | prompt | llm | StrOutputParser()
```

The LangChain approach demonstrates why hybrid retrieval is powerful: vector search
catches semantically relevant content the graph might miss; graph traversal catches
relational context the vector search misses. Both feed into the same prompt.

### LlamaIndex GraphRAG

LlamaIndex provides a `KnowledgeGraphIndex` and `PropertyGraphIndex` that build
graph structures from documents and expose graph-aware query engines:

```python
from llama_index.core import KnowledgeGraphIndex

index = KnowledgeGraphIndex.from_documents(
    documents,
    max_triplets_per_chunk=10,
    include_embeddings=True,  # hybrid: graph + vector
)

query_engine = index.as_query_engine(
    include_text=True,         # include source text with graph context
    response_mode="tree_summarize",  # hierarchical summarization
    embedding_mode="hybrid",   # use both graph traversal and vector similarity
    similarity_top_k=5,
)
response = query_engine.query("What are the main themes?")
```

### Key Patterns to Borrow for UNIUN

From Neo4j/LangChain:
- **Hybrid retrieval**: use vector similarity to find seed nodes, then traverse
  the graph for relational context. This is exactly UNIUN's planned approach.
- **Entity extraction before graph query**: identify entities in the query first,
  then use those entities as graph traversal seeds.
- **Full-text index on entity names**: fast lookup of graph nodes by name.

From LlamaIndex:
- **Tree summarization**: hierarchical summaries (community summaries) enable
  efficient global queries without reading all content.
- **Include source text**: always return the original note content alongside
  the graph structure — the LLM needs both.

---

## Summary — What This Means for Shiv and UNIUN

UNIUN is in an unusually good position for GraphRAG. Unlike most applications that
must build a knowledge graph from scratch using expensive LLM extraction calls,
UNIUN's graph is a **native byproduct of how Nostr works**:

- Every `e` tag in a note is a verified, user-created edge between two notes.
- Every `t` tag is a user-created edge between a note and a topic entity.
- Every entry in the NIP-02 contact list is a verified social graph edge.
- Every reply thread is a directed conversation graph.

These edges are not inferred — they are explicit assertions by users. This makes
UNIUN's graph more reliable than LLM-extracted graphs, which can hallucinate or
mis-extract relationships.

The mobile GraphRAG stack for Shiv:
1. **Graph storage**: Isar (existing) or a shadow SQLite graph table — store
   note→note edges (from e-tags), note→tag edges (from t-tags), user→user edges
   (from follow list).
2. **Degree centrality**: computed on the stored edge table; higher-degree notes
   are more important for community detection and context ranking.
3. **Community detection**: offline, in a background isolate, using tag co-occurrence
   clustering or a lightweight Louvain implementation. Cached as community summaries.
4. **Community summaries**: generated once per community by Gemma 2B, stored locally.
   Regenerated only when community membership changes significantly.
5. **Query pipeline**: embed query → find seed notes → BFS graph traversal (2 hops)
   → fetch community summaries → assemble prompt → Gemma 2B generates answer.
6. **Query routing**: detect query type (global vs. local vs. direct) and choose
   the appropriate retrieval strategy.

The result is a system that can answer "What have I been learning about lately?"
as accurately as "What did I write about relays?" — the first using community
summaries, the second using vector similarity, both using the same Gemma 2B on
device.
