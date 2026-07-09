# RBX Server Expansion

Cross-server **world synchronization** for Roblox, built on a **git-like update model**.

Every server in one experience shares a single world. When an instance under the
sync root changes on one server — and **only** when it changes — that change is
captured as a versioned *commit*, pushed to a shared log, and applied by every
other server in version order. The result: multiple servers that behave as if
players were all in **one server**.

> Pure `.luau` ModuleScripts — no build step. Drop them into Studio and go.

---

## How it works (the git analogy)

| git | RBX Server Expansion |
| --- | --- |
| Working tree | The live `workspace` on each server |
| A tracked file | A tracked instance (stable id in the `SXID` attribute) |
| A diff | An **op**: `create` / `update` / `delete` |
| A commit | A batch of ops + author server + version number |
| Commit hash / order | A globally atomic **version number** (MemoryStore HEAD counter) |
| The remote repo | The shared **commit log** (MemoryStore SortedMap) |
| `git push` | Reserve a version, write the commit, notify peers |
| `git pull` | Read commits after your local HEAD and apply them |
| A shallow clone / pack | A periodic **world snapshot** (DataStore) for new servers |
| Merge policy | **Latest version wins**, per property (total-order LWW) |

Data flow:

```
local change ──collect──▶ commit ──push──▶ reserve version + write log + Publish{v}
        ▲                                                    │
        │                                                    ▼
     Applier ◀──apply── commits after localHEAD ◀──pull── Publish / reconcile timer
```

Three Roblox services do the heavy lifting:

- **MemoryStoreService** — the atomic HEAD counter and the commit log (shared, low-latency).
- **MessagingService** — a tiny "new version N" ping so peers pull immediately.
- **DataStoreService** — periodic world snapshots so a brand-new server can rebuild the world, then replay recent commits on top.

---

## Files

```
src/ServerExpansion/
  init.luau          Facade: ServerExpansion.start(config?)
  Config.luau        Overridable settings (root, intervals, TTLs, topic, ...)
  Codec.luau         Roblox datatypes <-> JSON-safe form (Instance refs by id)
  Schema.luau        Which classes/properties are trackable (extensible)
  Identity.luau      Stable cross-server ids + id<->instance registry
  ChangeTracker.luau Detects local changes, produces ops, coalesces per interval
  Applier.luau       Applies remote ops locally with feedback-loop suppression
  Repository.luau    Shared repo: atomic HEAD, commit log, snapshot, push/pull
  Replicator.luau    Orchestrates detect→push and notify/reconcile→pull→apply
src/example/
  DemoSynced.luau    A demo part that stays in sync across servers
```

---

## Installation

These are plain ModuleScripts. `init.luau` is the module entry point, and the
other files are its children. You have two options.

### Option A — Rojo (recommended)

A folder containing `init.luau` becomes a `ModuleScript` whose siblings are its
children. Point your `default.project.json` at `src/ServerExpansion` mapped into
`ServerScriptService`, and `src/example/DemoSynced.luau` as a `Server Script`.

### Option B — Manual in Studio (no tooling)

1. In `ServerScriptService`, create a **ModuleScript** named `ServerExpansion`.
2. Paste the contents of `init.luau` into it.
3. Inside that ModuleScript, create child **ModuleScripts** named exactly:
   `Config`, `Codec`, `Schema`, `Identity`, `ChangeTracker`,
   `Applier`, `Repository`, `Replicator` — paste each file's contents.
4. Create a **Script** in `ServerScriptService` and paste `DemoSynced.luau`
   (or your own code that calls `ServerExpansion.start()`).
5. **Game Settings → Security → Enable Studio Access to API Services** (required
   for MemoryStore / MessagingService / DataStore).

---

## Usage

```lua
local ServerExpansion = require(game.ServerScriptService.ServerExpansion)

-- Sync the entire workspace with defaults:
ServerExpansion.start()

-- Or override any config field:
ServerExpansion.start({
    getSyncRoot = function() return workspace.SharedWorld end,
    commitInterval = 0.5,
    syncPlayerCharacters = true,
    debug = true,
})
```

That's it. From then on, any change your game makes to a tracked instance under
the sync root replicates to every other server. Your game code doesn't call any
special API — it just edits instances.

**Attributes** are synced automatically and completely — every attribute on a
tracked instance, including custom ones added at runtime, replicates (unlike
properties, attributes are fully enumerable, so no whitelist is needed).

Sync more **properties** or classes at runtime:

```lua
local ServerExpansion = require(game.ServerScriptService.ServerExpansion)

-- Add properties to a class group:
ServerExpansion.Schema.add("BasePart", { "Transparency" })
ServerExpansion.Schema.extend("BoolValue", { "Value" })

-- Or a GLOBAL custom whitelist: for EVERY tracked instance, if it actually has
-- the property it is synced; if not, it is ignored for that instance.
ServerExpansion.Schema.addCustom({ "Transparency", "CanCollide" })
```

### What gets synced

- **Properties**: whatever the per-class schema lists *and* the instance actually
  exposes (broad defaults for parts, models, humanoids, lights, sounds, effects,
  constraints, GUIs, UI helpers, value objects, …). Extend as shown above.
- **Attributes**: all of them, always — added, changed, and removed.
- **Structure**: instances being created, reparented, and deleted.
- **Only changes**: unchanged instances/properties/attributes send nothing.

---

## Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `getSyncRoot` | `() -> workspace` | Root instance whose descendants are synced |
| `idAttribute` | `"SXID"` | Attribute name for the cross-server id |
| `commitInterval` | `0.5` | Seconds between flushing local changes |
| `reconcileInterval` | `10` | Seconds between fallback pulls (missed messages) |
| `snapshotInterval` | `60` | Seconds between world snapshots (elected writer) |
| `commitTtl` | `3600` | Commit lifetime in the log (seconds) |
| `maxOpsPerCommit` | `200` | Cap ops per commit (rate-limit safety) |
| `syncPlayerCharacters` | `true` | Also sync player Characters as remote avatars |
| `classBlacklist` | `{Camera, Terrain}` | Classes never synced |
| `debug` | `false` | Verbose logging |

---

## Limits & caveats (please read)

Roblox has no native shared world; this framework stitches one together from
rate-limited services. Design accordingly:

- **No arbitrary-property reflection.** Luau can't enumerate every *property* of
  an instance, so a per-class **whitelist** (`Schema.luau`) decides which
  properties sync — add to it via `Schema.add` / `addCustom`. **Attributes**, by
  contrast, *are* enumerable and so are synced in full with no whitelist.
- **Rate limits are real.** MessagingService messages are ≤ 1KB and throttled;
  MemoryStore values are ≤ 32KB with a per-player request budget. This suits
  **world state that changes at human speed** (doors, builds, ownership, toggles,
  item positions). It **cannot** stream per-frame physics of thousands of parts.
  Fast movement (including players) is coalesced/throttled and will show latency.
- **Conflict resolution is last-writer-wins**, per property, by version order —
  exactly "the latest version wins". There is no 3-way merge.
- **Only changes are sent.** Unchanged instances cost nothing. This is the core
  of the model, not an optimization you configure.
- **Snapshots are bounded** by the DataStore value size (~4 MB serialized). Very
  large worlds may need chunked snapshots (not implemented in v1).
- **Server only.** `start()` errors if called on a client.

---

## Testing across servers

MemoryStore / MessagingService only work in a **published** experience with
**multiple servers**, so this can't be exercised locally:

1. Install the modules (above) and add `DemoSynced` as a Server Script.
2. Enable *Studio Access to API Services* and **publish** to a test place.
3. Join with **2+ clients** so you land on different servers (`game.JobId` differ).
4. Verify:
   - The demo part orbits/recolors on one server and **mirrors within ~1s** on the others.
   - Create a tagged instance on server A → it **appears** on server B.
   - Delete it on A → it **disappears** on B.
   - A freshly started third server **rebuilds the current world** from the snapshot instead of starting empty.
   - Change the same property on two servers at once → all converge to the **latest** value.
   - No jitter/echo (a value doesn't bounce back and forth).

---
---

# 中文说明

## 这是什么

面向 Roblox 的**跨服务器"世界同步"框架**，采用**类 git 的更新模型**。

同一个体验（experience）下的多个服务器**共享同一个世界**：同步根下的某个实例发生改动时——而且**仅当**它改动时——这次改动会被记录成一个带版本号的 **commit**，推送到共享日志，其它所有服务器再按版本顺序应用它。效果就是多个服**像在一个服里一样**。

> 纯 `.luau` ModuleScript，**不用编译**，拖进 Studio 即可用。

## 工作原理（git 类比）

| git | 本框架 |
| --- | --- |
| 工作区 | 每个服务器上实时的 `workspace` |
| 被追踪的文件 | 被追踪的实例（`SXID` 属性里的稳定 id） |
| diff | 一个 **op**：`create` / `update` / `delete` |
| commit | 一批 op + 作者服务器 + 版本号 |
| commit 哈希/顺序 | 全局原子**版本号**（MemoryStore HEAD 计数器） |
| 远程仓库 | 共享 **commit 日志**（MemoryStore SortedMap） |
| `git push` | 抢一个版本号、写入 commit、通知其它服 |
| `git pull` | 读取本地 HEAD 之后的 commit 并应用 |
| 浅克隆 / pack | 周期性**世界快照**（DataStore），供新服 bootstrap |
| 合并策略 | **最新版本优先**，逐属性（全序 last-writer-wins） |

三个官方服务分担工作：

- **MemoryStoreService** —— 原子 HEAD 计数器 + commit 日志（共享、低延迟）。
- **MessagingService** —— 广播一个极小的"有新版本 N"通知，让其它服立刻 pull。
- **DataStoreService** —— 周期性世界快照，让全新服务器先重建世界，再重放最近的 commit。

## 安装

这些是普通 ModuleScript：`init.luau` 是模块入口，其余文件是它的子模块。两种方式：

**方式 A —— Rojo（推荐）**：含 `init.luau` 的文件夹会变成一个 `ModuleScript`，同目录其它文件成为它的子级。把 `src/ServerExpansion` 映射进 `ServerScriptService`，`src/example/DemoSynced.luau` 作为 Server Script。

**方式 B —— Studio 手动（无工具）**：
1. 在 `ServerScriptService` 建一个 **ModuleScript**，命名 `ServerExpansion`。
2. 把 `init.luau` 的内容粘进去。
3. 在它里面建子 **ModuleScript**，命名严格为：`Config`、`Codec`、`Schema`、`Identity`、`ChangeTracker`、`Applier`、`Repository`、`Replicator`，各自粘贴对应文件内容。
4. 在 `ServerScriptService` 建一个 **Script**，粘贴 `DemoSynced.luau`（或你自己调用 `ServerExpansion.start()` 的代码）。
5. **Game Settings → Security → 打开 Enable Studio Access to API Services**（MemoryStore/MessagingService/DataStore 必需）。

## 用法

```lua
local ServerExpansion = require(game.ServerScriptService.ServerExpansion)

-- 用默认配置同步整个 workspace：
ServerExpansion.start()

-- 或覆盖任意配置项：
ServerExpansion.start({
    getSyncRoot = function() return workspace.SharedWorld end,
    debug = true,
})
```

就这样。之后你的游戏对同步根下被追踪实例做的任何改动都会复制到其它所有服。你的游戏代码不需要调用特殊 API —— 只管改实例即可。

**Attributes（属性/Attributes）自动完整同步**：被追踪实例上的每一个 attribute（包括运行时新增的自定义 attribute）都会复制——因为 attribute 可以枚举，所以不需要白名单。

运行时扩展要同步的**属性（Properties）**或类：

```lua
-- 给某个类加属性：
ServerExpansion.Schema.add("BasePart", { "Transparency" })
ServerExpansion.Schema.extend("BoolValue", { "Value" })

-- 或全局自定义白名单：对每个被追踪实例，若它确实有这个属性就同步，没有就忽略。
ServerExpansion.Schema.addCustom({ "Transparency", "CanCollide" })
```

**同步的内容**：
- **属性 Properties**：schema 里列出的、且实例确实拥有的（对 Part/Model/Humanoid/灯光/声音/特效/约束/GUI/UI 组件/Value 对象等有较广的默认覆盖），可按上面扩展。
- **Attributes**：全部，始终同步——新增、修改、删除都同步。
- **结构**：实例的新建、改父级、删除。
- **只发有改动的**：没变的实例/属性/attribute 不发任何东西。

## 限制与注意事项（务必阅读）

Roblox 没有原生共享世界，本框架是用有配额限制的服务拼出来的，请据此设计：

- **无法反射任意属性（Property）**：Luau 拿不到实例的全部属性，所以由按类的**白名单**（`Schema.luau`）决定同步哪些，可用 `Schema.add` / `addCustom` 扩展。而 **Attributes** 可以枚举，所以全部完整同步、无需白名单。
- **速率限制是真实存在的**：MessagingService 单消息 ≤ 1KB 且有频率上限；MemoryStore 值 ≤ 32KB 且按人数给请求预算。它适合**以人类速度变化的世界状态**（门、搭建、归属、开关、道具位置），**无法**逐帧串流成千上万个 Part 的物理。快速移动（含玩家）会被合并/节流并有可见延迟。
- **冲突取最新版**：逐属性、按版本顺序的 last-writer-wins —— 正是"最新版本优先"。没有三方合并。
- **只发有改动的**：未改动的实例零开销。这是模型的核心，而非可配置的优化。
- **快照有大小上限**：受 DataStore 值大小限制（序列化后约 4MB）。超大世界需要分块快照（v1 未实现）。
- **仅服务器**：在客户端调用 `start()` 会报错。

## 跨服测试

MemoryStore / MessagingService 只在**已发布**且**多服务器**的体验中生效，本地跑不了：

1. 按上面安装模块，把 `DemoSynced` 作为 Server Script 加入。
2. 打开 *Studio Access to API Services* 并**发布**到测试 place。
3. 用 **2 个以上客户端**加入，确保分到不同服（`game.JobId` 不同）。
4. 验证：
   - 演示方块在一个服里绕圈/变色，其它服**约 1 秒内跟着同步**。
   - 在 A 服新建实例 → B 服**出现**；在 A 服删除 → B 服**消失**。
   - 新开的第三个服通过快照**重建当前世界**，而不是空场景。
   - 两个服同时改同一属性 → 最终都收敛到**最新**值。
   - 没有抖动/回环（数值不会来回跳）。
