# 源项目案例：长期 Agent 的工程问题

> 这份文档记录的是 Continuum Chat **源产品**在长期真实使用中遇到、验证并解决过的工程问题。  
> 公开仓库仍然只提供脱敏、可运行、可复现的参考基线；本文中的高级机制用于展示设计思路与验证方法，**不等于所有实现都已完整开源**。

这些案例关注的不是“用了哪个模型”，而是模型外面的系统如何避免长期运行后逐渐失真。

## 1. Memory：检索命中不等于真正被模型看到

### 问题

早期实现里，只要 Memory 检索返回了一张卡，就可能把它计为一次 `hit`。但真实链路中，候选卡还可能因为分数阈值、冷却、布局策略或本轮上下文预算被过滤。

这会产生一个很危险的错觉：

> 指标显示“这条记忆经常被使用”，但模型实际上可能一次都没看到。

### 设计决定

把“检索候选”和“Provider-visible 注入”拆成两个事件。

只有当某个 Memory revision **最终进入本轮发送给 Provider 的 Context** 时，才写入 durable injection receipt，并更新 hit / last_hit_at。

同一个 generation + card + revision 的 receipt 必须幂等，避免重试或恢复流程重复计数。

### 结果

这样 Memory 指标开始回答一个更有价值的问题：

> “模型到底真的看到了哪些记忆？”

而不是：

> “检索器曾经捞到过哪些候选？”

### 公开仓库边界

公开基线保留独立 Memory 服务与 recall 边界，但不自动把 Memory 注入聊天 Context。这个案例展示源产品为什么后来把“检索”和“真实注入”分开计量。

---

## 2. Tools：工具执行成功，不代表下一轮 Agent 知道自己做过什么

### 问题

Agent 调工具后，工具可能已经真实完成动作，但如果下一轮 Context 只保留自然语言回复，没有保留可复用的执行事实，模型就会开始猜：

- 上一轮到底有没有执行；
- 参数是什么；
- 成功还是失败；
- 结果是否已经送达用户。

这会导致重复执行、错误补偿和“凭感觉续写”。

### 设计决定

引入 **execution receipt**：

```text
decide → call tool → execute → normalize result → persist receipt
                                           ↓
                                  next-turn context
```

receipt 只保存下一轮真正需要的稳定事实，不把原始 stdout、大段 JSON 或调试噪声长期塞进 Context。

### 结果

工具链从“这一轮能调用”升级成：

> **这次动作发生过，而且后续决策能够可靠地知道它发生过。**

这也是长期 Agent 与一次性 Chatbot 的关键差别之一。

### 公开仓库边界

公开基线展示 MCP transport 与手动调用，但不声称包含完整自动 Tool loop。这个案例记录源产品在真实自动执行链中补上的连续性层。

---

## 3. Context：连续性不能靠静默裁历史换性能

### 问题

长窗口变慢时，一个很自然的优化想法是：

> “只把最近 N 条消息发给模型，旧消息摘要掉。”

源产品实际验证后否决了这种做法：在同一连续会话里，静默裁剪已经发生的 Provider-visible 历史，会改变角色行为、承诺和工具事实的语义基础。

### 设计决定

Context ownership 被拆成几类：

- **canonical history**：真实发生过的对话事实；
- **Context Epoch**：只有用户主动开启新窗口时才形成边界；
- **immutable handoff**：新 Epoch 短期复用上一窗口的固定快照，而不是每轮滚动重算；
- **Context Inspector**：在最终 Provider 发送边界旁路观察“这轮到底发了什么”，而不是只看理论拼接器。

性能问题优先从 prefix / KV 稳定、重复拼接、动态块、Provider 调用结构、前端流式处理等方向优化，不拿连续性本身做交换。

### 结果

Context 变成一个有明确 owner、生命周期和审计面的系统，而不是“若干 Prompt 字符串拼在一起”。

### 公开仓库边界

公开基线已经保留 canonical history 与 Context Epoch。源产品的 handoff、Inspector 和更细 Context ownership 机制目前只在本文中以设计案例公开。

---

## 4. Pending：长期原则不能伪装成“永远没完成的待办”

### 问题

早期 Pending 账本容易把这类内容也当任务：

- “以后更主动一点”；
- “从今天起不要再这样”；
- “长期保持某种关系行为”。

它们没有一个明确的完成时刻，于是会永久滞留，反复进入下一轮上下文，最后变成模型每轮都被提醒的“幽灵任务”。

### 设计决定

Pending 被收紧为 **finite obligation**：

只有“一次可以完成的回复 / 动作 / 工具结果 / artifact / 条件满足后的有限动作”才能进入账本。

同时增加：

- `actionable`
- `waiting_user`
- `paused`
- `blocked`

以及 progress checkpoint，用来记录“已经做到哪、下一步是什么、在等谁、什么条件恢复”。

长期性格、关系原则和行为偏好应该属于 Prompt / Policy / Memory / Self-model 等其他 owner，而不是 Pending。

### 结果

Pending 从“所有没解决的东西”变成真正可执行、可结束、可恢复的有限义务账本。

---

## 5. Proactive：主动行为必须只有一个真实 owner

### 问题

长期 Agent 往往同时存在：

- 主动联系；
- 自由活动；
- 计划中的未来动作；
- 事件触发；
- 工具执行；
- 去重与节流。

如果多套 scheduler / trigger 都拥有“最终发送权”，就会出现重复触发、互相覆盖，甚至无法判断一条主动消息到底是谁发起的。

### 设计决定

把 Trigger Policy、计划状态和执行链拆开，并明确：

> **触发判断可以来自多个信号，但真实执行权必须归到单一 owner。**

同时把真实动作写成可追踪的 canonical facts / receipts；重复抑制和 NO_RESPONSE 也保留独立语义，不能伪装成普通 assistant 文本。

### 结果

主动行为不再是“定时器偶尔戳一下模型”，而是可以解释：

- 为什么这次触发；
- 为什么没触发；
- 做了什么；
- 为什么被抑制；
- 下一轮模型能看到什么。

---

## 6. Self Model：人格自我维护不能退化成“模型自己夸自己”

### 问题

长期 Agent 会逐渐形成类似“我通常怎么做 / 我是什么样的人”的稳定自我认识。最粗暴的做法是把这些内容直接写进 Prompt 或 Memory，但这样会有几个问题：

- 用户一句评价就可能被永久写成人格；
- 模型在 maintenance 里重复“我就是这样”会形成自证循环；
- 一条偶发行为可能被过度概括成稳定特质；
- 人格一旦热更新，当前长窗口的输入可能在用户无感知的情况下突然改变。

### 设计决定

源产品把 **Self Model** 从普通 Memory 中拆成独立系统，并把“谁可以提议、谁可以修改、什么算证据、什么时候生效”分开。

核心链路是：

```text
真实对话 / 工具 / 主动行为
        ↓
canonical evidence
        ↓
Curator: support / contradiction / no_match
        ↓
review suggestion（只提议，不改人格）
        ↓
主 Agent review / revise
        ↓
重新校验当前 evidence
        ↓
Deterministic Gate
        ↓
append-only claim version
        ↓
future ContextEpoch adoption
```

关键约束包括：

- Curator **没有**人格 claim mutation 权限；
- suggestion、summary、review event 都不算成熟度证据；
- maintenance 里模型自己重复某条自我描述，不算“这条人格又被现实支持了一次”；
- 单一 user preference 不能直接建立人格；
- 只有当前有效、agent-origin、彼此独立的真实证据才能推动成熟度；
- 至少需要多个独立 evidence roots，并且没有有效 contradiction，claim 才可能从观察态进入稳定态；
- 最终成熟度由 deterministic Gate 决定，不由 LLM 自报；
- Provider-visible adoption 只在 **ContextEpoch 边界**冻结，当前窗口不会因为后台 store 变化而偷偷换人格。

### 为什么不直接塞进 Memory

Memory 更适合回答：

> “以前发生过什么？”

Self Model 要回答的是：

> “基于一段时间的真实行为，我现在对自己的稳定认识是什么？”

两者的证据标准、生命周期和修改权限并不相同。把它们混在一起，会让一次事件既是“历史事实”又直接变成“人格定义”。

### 结果

Self Model 从“写几条人设 Prompt”变成了一条可审计的自我维护链：

> **真实行为产生证据 → 候选解释 → 主 Agent 复核 → 确定性门控 → 新窗口边界采用**

这让人格变化既可以发生，又不会因为一句评价、一次偶发行为或 maintenance 自我复述而无限漂移。

### 公开仓库边界

公开基线当前不包含这套 production Self Model store / curator / maintenance runtime。这里仅公开经过脱敏的架构与工程取舍；私人人格内容、真实 evidence 和生产数据库不会进入公开仓库。

---

## 这些案例共同说明什么

Continuum Chat 的长期迭代逐渐形成了几个稳定原则：

1. **真实发生过的事实要有 canonical owner。**
2. **候选、计划、执行、可见结果必须分层。**
3. **模型外状态要有生命周期，而不是无限堆 Prompt。**
4. **任何自动化都需要 receipt / trace / regression 才能长期维护。**
5. **用户可见连续性优先于“看起来更省 token”的静默裁剪。**

公开基线刻意保持小而可运行；源产品则继续验证这些更复杂的生命周期问题。两者的关系不是“Demo vs 真项目”，而是：

> **Public reference = 可安全复现的工程切片**  
> **Source product = 用真实长期使用持续验证这些边界的生产系统**

参见：[架构说明](ARCHITECTURE.md) · [README](../README.md)
