# Tuolaji (升级) — Standard Rules

The complete ruleset enforced by this engine. Chinese terms are given in
parentheses for reference. Card notation: `S`=♠, `H`=♥, `C`=♣, `D`=♦,
`sJ`=small joker, `bJ`=big joker.

## 1. Players and objective

- Four players in two partnerships. Partners sit opposite each other: seats
  0 & 2 versus seats 1 & 3 (or A & C versus B & D).
- Two standard decks plus four jokers — **108 cards**.
- Each deal is played between a **banking team** (defending) and an **attacking
  team**. The attackers must collect **80 points** to win the deal; with fewer
  than 80, the banking team wins.
- The winning team advances and banks the next deal.

## 2. Cards and points

- Suits ♠ ♥ ♣ ♦; ranks `2 3 4 5 6 7 8 9 10 J Q K A`.
- Each card appears **twice** (once per deck). The two copies are physically
  distinct, which matters for pairing.
- Point cards: each **5 = 5**, each **10 = 10**, each **K = 10**. Everything
  else (jokers, A, Q, J, and the other ranks) = 0.
- A full deal holds **200 points**.

## 3. Level, trump, and ordering

- Each partnership has a **level** (级), a rank starting at 2. A deal is played
  at the **banking team's level**.
- **Level cards** (级牌): every card whose rank equals the level. They are
  always trump, whatever suit they are printed in.
- **Trump** (主牌): all level cards, all ordinary cards of the trump suit, and
  both jokers.
- **No-trump (NT)** (无主): only level cards and jokers are trump.
- **Side suit** (副牌): any non-trump ordinary card.
- **Logical suit**: all trump cards form one suit; each side suit is its own.

### 3.1 Ordering (low to high)

- **Side suit**: `2 3 4 5 6 7 8 9 10 J Q K A`, with the level rank removed.
- **Trump chain**: ordinary trump-suit cards (ordered as a side suit, level
  removed) < off-suit level cards < trump-suit level cards < small joker <
  big joker.
- **NT chain**: level cards < small joker < big joker.
- All off-suit level cards are equal to each other; all trump-suit level cards
  are equal to each other. Equal ranks are decided by play order: the earlier
  card wins.

## 4. Card combinations

- **Single** (单张): exactly one card.
- **Pair** (对子): exactly two cards of the same rank and the same physical
  suit. Jokers pair only like-with-like (two small or two big). Two level cards
  of different printed suits are **not** a pair.
- **Tractor** (拖拉机): two or more consecutive pairs of one logical suit.
  "Consecutive" means adjacent in the ordering chain (side or trump). A side
  tractor is one physical suit; a trump tractor may cross printed suits along
  the trump chain. Minimum two pairs.
- **Throw** (甩牌): two or more cards of one logical suit that can be split
  into singles, pairs, and tractors, but are not themselves a single, pair, or
  tractor.

## 5. The deal and the kitty

- Deal 25 cards to each player (100 cards). The remaining **8 cards are the
  kitty** (底牌).
- After declarations, the banker receives the kitty (holding 33 cards), then
  **buries exactly 8 cards** face down. Those buried cards are the kitty for
  scoring.
- The banker leads the first trick.
- Cards are dealt one card at a time, starting with the seat **after the
dealer** and rotating clockwise. The dealer is a distinct, rotating role from
the banker: it only fixes where dealing begins (see §11).

## 6. Declarations (亮主)

Declarations choose the trump suit (or NT) and happen while the deal is being
dealt. The cards used must be in the declarer's hand.

- **Single** (单张): one level card declares that card's printed suit. Legal
  only while no declaration exists.
- **Pair** (对子): two level cards of the same printed suit. It overrides a
  single. Once a pair is declared it is **final**, unless enhanced joker
  override is enabled.
- **Joker pair** (对王): two small jokers or two big jokers declare **No-Trump**.
  NT is always final.
- **Joker override** (增强对王反主, optional setting): when enabled, a
  joker pair may override a declared level-card pair. A level-card pair still
  cannot override another pair, and NT remains final.
- If nobody declares, the deal is **No-Trump**.
- The app enforces a configurable declaration window: each declaration
  guarantees a minimum time for someone to override it, and a call that cannot
  be overridden ends the window immediately.

## 7. Leading (领牌)

The lead is one combination; all its cards must belong to one logical suit.

- Cards must be held and used once, and must form a valid single, pair,
  tractor, or throw.
- **Throw unbeatability**: a throw is legal only if **no other player holds a
  same-suit combination that beats any of its components**. Components are
  checked in the order **single → pair → tractor**:
  - a single is beaten by any higher single;
  - a pair is beaten by any higher pair;
  - a `k`-pair tractor is beaten by a same-suit tractor of at least `k` pairs
    that contains a higher `k`-pair window.
  - A component can only be beaten by the **same type** — a higher single never
    beats a pair, and so on.
- **Throw penalty**: an illegal throw is not rejected. The engine plays the
  first beatable component, returns the rest to the leader's hand, and that
  component stands as the lead. Components are tried by type
  (**single → pair → tractor**) and, within a type, from the **lowest rank
  upward**, so the choice does not depend on the order the leader listed the
  cards. If no specific component can be isolated, the engine plays the
  smallest card(s): a pair if the smallest face has two copies, otherwise a
  single.

## 8. Following (跟牌)

Every other player plays exactly `N` cards, where `N` is the lead's card count.

- Let `S` be the lead's logical suit and `H` the number of `S` cards in hand.
- If `H = 0` (void, 缺门), any `N` cards are legal.
- Otherwise play exactly `min(H, N)` cards from `S`. You may not play a card
  outside `S` while you still hold an `S` card — in particular, you may not
  ruff while holding the led suit.
- When the lead contains pairs or tractors, fill slots in the priority
  **tractor slots > pair slots > single slots**, maximizing the number of
  complete pairs/tractors:
  - **Tractor slot**: play a same-suit tractor (of the lead's length if you
    have one; otherwise your longest), then same-suit pairs, then singles. A
    single hand tractor may cover more than one tractor slot, but it is played
    whole: you must preserve your longest tractor rather than split it to fill
    slots separately.
  - **Pair slot**: play a same-suit pair if you hold one.
  - **Single slot**: play same-suit singles. A same-suit pair or tractor may be
    broken into singles **only** when no pair or tractor slot still needs it.
  - Never break a same-suit pair/tractor for a lower-priority slot while a
    higher-priority slot is still unfilled by a pair.
- Legality requires only the count and this slot priority. Matching the lead's
  exact structure is required to **win**, not to follow.

## 9. Winning the trick

Candidates are decided by the lead's logical suit and structure.

- **Same-suit play**: all `N` cards belong to the lead's logical suit. Only a
  play whose structure matches the lead can compete.
- **Ruff / kill** (杀牌): only against a **side-suit** lead. The player is void
  in the lead suit, plays all `N` cards as trump, and the play's structure
  exactly matches the lead:
  - single → any one trump;
  - pair → a trump pair;
  - `k`-pair tractor → a trump tractor of exactly `k` consecutive pairs;
  - pure-single throw (no pair/tractor components) → any `N` trumps;
  - throw containing pairs/tractors → a trump play whose components exactly
    match the lead's.
  A play that is not all trump, or whose structure does not match, is a
  **discard** (垫牌) and cannot win.
- If the lead is trump, only same-suit trump plays compete.
- If the lead is a side suit:
  - valid ruffs beat every same-suit play;
  - for a **throw** lead, if no valid ruff exists the leader wins; a
    same-suit follow cannot beat a legal throw (unbeatability was checked when
    it was led);
  - otherwise the highest valid ruff wins; if there is none, the highest
    same-suit play wins.
- **Comparison**: compare components from strongest to weakest. Component
  strength is **tractor > pair > single**; within a slot compare the top rank,
  then the length. For a tractor compare the highest pair, then the next, and
  so on; for a pure-single throw compare the cards as singles, highest first.
  Equal comparisons go to the **earliest play** (the leader first).

## 10. Scoring and levels

Let `P` be the attacking team's points (trick points plus any kitty scoop).

| Attacker points `P` | Result |
|---|---|
| `P = 0` | banking team rises 3 levels |
| `1 ≤ P ≤ 39` | banking team rises 2 levels |
| `40 ≤ P ≤ 79` | banking team rises 1 level |
| `80 ≤ P ≤ 119` | attackers take over the bank; rise 0 |
| `P ≥ 120` | attackers take over the bank; rise `floor((P − 80) / 40)` |

- **Kitty scoop** (抠底): if the attackers win the final trick, the kitty's
  points are added to `P`, multiplied by the final lead's structure: **×8** if
  it contains a tractor, otherwise **×4** if it contains a pair, otherwise
  **×2** (pure singles).
- A team's level never exceeds **A**; advancing past A caps at A.
- The winning team banks the next deal: if the banking team holds it keeps the
  bank; if the attackers win they become the banking team.

## 11. The banker seat

- The bank team for a deal is the previous deal's winner: the banking team if
  it held, otherwise the attackers.
- Within a team the banker **alternates between its two seats** each deal that
  team banks. A team banking for the first time starts on its lower seat.
- Exception — a table's first deal: the final declarer banks; if nobody
  declared, seat 0 banks.

## 12. Epochs

- The target level is **A**.
- A partnership completes an **epoch** when it wins a deal as the banking team
  while that deal was played at level A.
- On completion, that partnership's epoch count increases and its level wraps
  past A by the levels it would have gained (so +1 restarts at 2, +2 at 3, and
  +3 at 4). The other partnership keeps its own epoch and level.
- Completing an epoch is reported but does **not** end the table; play
  continues until the players leave.

## 13. Terminology

| Term | Meaning |
|---|---|
| level (级) | the rank being played this deal |
| level card (级牌) | any card of the level rank; always trump |
| trump (主牌) | level cards, trump-suit cards, jokers |
| side suit (副牌) | non-trump ordinary cards |
| banker (庄家) | the seat that buries the kitty and leads the first trick |
| banking team (庄家方) | the defending partnership |
| attackers (闲家) | the opposing partnership |
| single (单张) | exactly one card |
| pair (对子) | two cards of the same rank and physical suit |
| tractor (拖拉机) | two or more consecutive pairs of one logical suit |
| throw (甩牌) | a same-suit mix of singles, pairs, and/or tractors |
| lead / follow (领牌 / 跟牌) | start a trick / answer it |
| ruff (杀牌) | trump a side-suit lead after becoming void |
| discard (垫牌) | a void play that does not ruff; cannot win |
| kitty (底牌) | the 8 buried cards |
| scoop (抠底) | attackers win the final trick and score the kitty |
| trick (一墩) | one round of four plays |

## 14. Leaving and disconnects

- A seat may leave at any time. A seat that leaves **mid-deal does not void the
deal**: the remaining players play it out and the deal is scored normally, with
the empty seat auto-played by the server. Leaving therefore cannot be used to
avoid a loss, a bad trump, or an epoch.
- The vacated seat is reopened for a new player in the lobby, or at the
end-of-deal summary (the `Scoring` phase) before the next deal.
- Hands and the deal's hidden information stay hidden throughout; a player who
rejoins takes over the seat's remaining hand.
