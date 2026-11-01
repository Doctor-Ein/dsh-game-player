# DSH 调用接口交接：0.1 → 0.2

此文说明 DSH 模型可见接口和旧调用迁移。引擎协议版本为 v2，package 版本为 0.2.0。

## 接入方式不变

插件加载时只注册 `/game` 和 `game_attach({window?:string})`。成功连接后，在发起连接的当前会话注册 `game_shot`、`game_find`、`game_do`、`game_stop`；不新建会话。重复连接重新注册当前会话工具。

宿主仍使用原来的 commands / tools / attachments 服务，工具输出仍为 `{text, images?}`，由 renderer 展示图片和文字。无需修改 DSH 本体。新增能力能否在当前运行的 DSH 中完成注册，仍应通过重新加载插件并 attach 验收；独立引擎/协议回归不等同于宿主端到端验收。

## 模型可调用接口

| 工具 | 参数 | 相对旧版的变化 |
| --- | --- | --- |
| `game_attach` | `window?` | 参数不变；握手校验 PID、引擎 v2、坐标口径和代码指纹 |
| `game_shot` | `region?`, `scale?`, `overlay?` | 新增 overlay；文字返回 shotId、原图原点/尺寸、客户区原点/尺寸、实际 scaleX/scaleY |
| `game_find` | `template`, `record?`, `region?`, `threshold?`, `maxResults?` | 新增，录模板或查找；不点击 |
| `game_do` | `steps`, `capture?`, `every?`, `maxFrames?`, `scale?`, `region?` | 顶层参数和五种 step 不变；click 的 x/y 现在会生效，坐标统一为屏幕物理像素 |
| `game_stop` | `{}` | 参数不变；停止后必须重新 attach；未确认松手时明确返回失败说明 |

`game_shot.scale` 默认 .5，范围 .2–1。overlay 默认 false。`game_do` 默认采样，every 默认 1000ms，maxFrames 默认 6（最多 12），steps 必须为 1–60 项。QTE 参数没有增加或删除：`probe` / `probes` / `timeoutMs` / `holdMs` / `gapMs` / `intervalMs` / `then` 沿用。

## 坐标和 region 的迁移规则

- 截图、搜索和录制的 `region`：客户区内物理像素。可以整个省略；一旦传入，必须完整给出整数 `{x,y,w,h}`，x/y ≥ 0，w/h > 0。旧版部分字段省略、浮点坐标或负值自动纠正的调用不再兼容。
- region 的起点必须在客户区内，超过右/下边界的宽高会取交集。录模板更严格：区域必须完整位于指定 shotId 的原图内，每边 3–512px。
- 网格、匹配结果和鼠标 abs/click 的 x/y：虚拟桌面屏幕物理像素，允许负数。旧策略中按逻辑像素、截图缩放或经验补偿保存的坐标需要重新确认。
- 预览像素不是输入坐标；缩放后的宫格还有独立缩放，不能直接读取点击坐标。
- 省略 click 的 x/y：仍点击当前位置；同时给出：先移动再点击；只给一个会报错并中止块。`abs` 仍只移动。已有 waitfor QTE 不带 x/y 的点击保持原用法。

## game_find 的两种调用

录制模板：

```json
{"template":"zzz-enter-v1","record":{"shotId":"复制 game_shot 返回的值","region":{"x":100,"y":200,"w":120,"h":60}}}
```

返回裁片图片供检查，以及 text 中的 JSON，例如：

```json
{"mode":"record","template":"zzz-enter-v1","path":"实际保存路径","w":120,"h":60,"shotId":"该截图的标识","coordinateSystem":"virtual-desktop-physical"}
```

查找新截图：

```json
{"template":"zzz-enter-v1","region":{"x":0,"y":0,"w":800,"h":600},"threshold":0.9,"maxResults":5}
```

`template` 也可为绝对 PNG 路径（仅查找）。threshold 默认 .9，允许 .8–1；maxResults 默认 5，允许 1–20。text 中的 JSON 形状为：

```json
{"mode":"find","template":"zzz-enter-v1","matches":[{"x":-1621,"y":245,"w":23,"h":17,"score":1,"center":{"x":-1610,"y":253}}],"region":{"x":-1700,"y":200,"w":800,"h":600},"client":{"x":-1700,"y":200,"w":1920,"h":1080},"threshold":0.9,"matchMs":12,"coordinateSystem":"virtual-desktop-physical"}
```

数值均是格式示例，不对应当前游戏按钮。**matches 位于返回对象 text 内的 JSON 中，不是工具顶层字段。** 程序调用者需要解析 text；模型可直接阅读渲染出的 JSON。没有匹配时 matches 为 []。使用实际结果的 center.x/y：

```json
{"steps":[{"t":"mouse","a":"click","btn":"left","x":-1610,"y":253}]}
```

shotId 只索引当前手进程最近 16 次 game_shot 的未缩放原图；重启或过期后必须重新拍。命名模板跨手进程重启保留在 `%TEMP%\dsh-game-player\templates`，但清理 TEMP 会丢失。模板不允许同名覆盖；改用新名字。

匹配要求同尺寸、不透明 PNG、有辨识度的纹理。分辨率/UI 缩放/按钮状态改变时重录。score 为 `1 - RGB RMSE/255`，不是概率。录制只保存原图裁片，不保存网格或预览缩放。

## 错误和恢复

| 状态 | 调用者应如何处理 |
| --- | --- |
| 旧手、PID 或代码版本不一致 | 重开本 package 的手，然后重新 `/game` / game_attach |
| stop 后、断线后或更换手进程后 | 重新连接，不重复发送动作碰碰运气 |
| 窗口不在前台 | 让窗口回到前台后再执行动作 |
| 动作错误 | 本块会中止并尝试松手；检查返回 errors，不沿用原先剩余步骤盲点 |
| shotId 过期/跨窗口 | 重新 game_shot，从新 shotId 录制 |
| 没有匹配 | 检查模板状态、尺寸和搜索区域；不要猜坐标补偿 |
| 匹配超时或候选太多 | 收窄区域、提高模板辨识度或阈值 |
| 松手未确认 | 会话已停用，但不能当作输入已成功释放；检查手连接，必要时 F12 |

模板定位和 QTE 共用串行手进程。game_find 不会在 QTE 探针里运行，也不会自动同时守 QTE；战斗期间需要毫秒反射时继续使用 game_do 的 waitfor，不要改成模型反复调用 game_find。

## 升级验收

1. 重新加载 DSH 插件，重开手，再连接原会话。
2. 确认连接提示含 v2、代码指纹以及四个操作工具，其中包含 game_find。
3. 验证截图 overlay/shotId → 录制返回裁片 → 查找返回 matches → 使用实际 center 点击。
4. 用原来的 waitfor/probes 打一局验证 QTE，比较 trace 的 hit、waited、fires 和实际游戏结果。

当前已完成独立引擎/协议、工具执行、模板、模拟 QTE 和双屏光标回归；尚未完成运行中的 DSH 工具注册与实际游戏整条链路的人工验收。
