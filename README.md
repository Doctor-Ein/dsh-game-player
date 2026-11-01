# dsh-game-player

给模型屏幕截图和真实键鼠输入；由模型决定动作，常驻 PowerShell 手进程负责执行、采样和本地 QTE 反射。仅 Windows 10 1607+，不读游戏内存、不注入。

## 连接

1. 双击本 package 的 `start-gameplay.cmd`，完成 UAC 后保持手进程运行。
2. 在原来的 DSH 会话里输入 `/game`，或调用 `game_attach({window:"绝区零"})`。
3. 确认连接信息含引擎 `v2` 和代码指纹。更新引擎后必须重开手；旧版会被明确拒绝。

插件入口只注册，不启动进程；所有操作工具只挂到当前会话。停止、断线或手进程更换后必须重新连接。

接口参数、返回格式和旧调用迁移见 [DSH 接口交接](docs/interfaces-v2.md)。

## 工具

| 工具 | 用途 |
| --- | --- |
| `game_attach` | 接上手、绑定窗口，注册下面四个工具 |
| `game_shot` | 单帧预览，可裁客户区、缩放、加屏幕坐标网格；保留原图，返回 `shotId` |
| `game_find` | 从指定原图录模板，或在新截图中匹配模板，返回精确坐标和中心 |
| `game_do` | 执行动作块，采样多帧并返回编号宫格和 trace |
| `game_stop` | 停用会话并请求松手；松手未确认时明确报告 |

## 坐标：只用物理像素

`game_shot` / `game_find` 的 `region` 和录模板的 `record.region` 是**客户区内的物理像素**。窗口原点由手在每次请求时查询，移动窗口不需要重新连接。

网格标注、匹配结果 `x/y`、`center.x/y` 和 `game_do` 鼠标 `x/y` 都是**虚拟桌面的屏幕物理像素**。副屏在左侧或上方时坐标可以是负数。无需手动乘 Windows 缩放比例。

预览可能缩小；返回文字包含原图尺寸、屏幕原点、实际 X/Y 缩放和换算公式。宫格还会再次缩放，只用于观察，不能从宫格直接读取点击坐标。

## 录模板 → 精确定位 → 点击

```js
game_shot({ scale: 0.5, overlay: true })
// 返回 shotId，以及客户区和屏幕原点。

game_find({
  template: "zzz-enter-v1",
  record: { shotId: "上一步返回的值", region: { x: 2100, y: 1200, w: 180, h: 80 } }
})
// 坐标仅为格式示例，须按实际画面确定。工具从未缩放原图裁切并返回模板供检查。

game_find({ template: "zzz-enter-v1", threshold: 0.9,
  region: { x: 1900, y: 1000, w: 660, h: 440 } })
// matches: [{x,y,w,h,score,center:{x,y}}, ...]；无匹配时 []。

// 将实际返回的 center.x、center.y 填入 click：
game_do({ steps: [{ t: "mouse", a: "click", btn: "left", x: -960, y: 540 }] })
```

命名模板保存在手进程的 `%TEMP%\dsh-game-player\templates`，重开手后仍可使用，清理 TEMP 后会丢失。也可向 `template` 传本机绝对 PNG 路径查找。名字只接受字母、数字、`_`、`-`（最多 64 字符）；重复录制请用新名字。

原图 `shotId` 只保留当前手进程最近 16 次 `game_shot` 的索引；录制过期、跨窗口或越界时会报错。第一次框选可以稍宽，返回裁片后检查它是否包含了有辨识度的按钮文字/图案；无纹理纯色模板会被拒绝。

匹配是**同尺寸、无旋转的 RGB 像素匹配**，分数 `1 - RMSE/255`，默认阈值 `.9`（范围 `.8..1`）；它不是概率。尺寸每边 3–512 像素，最多返回 20 个去重结果，默认 5 个。使用不透明 PNG。游戏分辨率/UI 缩放、主题或按钮状态变化时重新录模板。动态背景会降低分数；优先用小而独特的区域，限定搜索范围。搜索 15 秒仍未完成会报错，F12 可中断。**模板匹配不进入 QTE 的探针循环。**

## 动作与安全

五种步骤保持不变：`key` / `mouse` / `wait` / `look` / `waitfor`。原有 QTE 检测器、双探针守卫和编号宫格保留。鼠标 `click` 带 `x/y` 时先定位再点击；省略两者则点击当前位置，`abs` 只移动。

- 截图、定位和输入工具检查连接/armed 状态。前台窗口不匹配时拒绝执行动作；步骤失败会停止块并松手，避免错误坐标之后继续点击。
- F12 急停覆盖反射动作的 hold/gap/wait；等待阶段每 20ms 内检查一次（不含 Win32/GDI 调用自身耗时）。
- `SendInput` 返回失败会报错；Windows UIPI 或桌面输入权限仍可能阻止输入。目标游戏以管理员运行时，手也应以管理员运行。
- 截图使用屏幕像素，窗口必须可见、无遮挡；独占全屏可能抓黑。相对鼠标移动的 raw input 灵敏度仍需按游戏标定。

## 文件与验证

`lib/index.js` 注册；`lib/hand-link.js` 管命名管道和版本；`lib/tools.js` 定义工具；`lib/helper.ps1` 按职责加载 Win32、截图、定位、输入、调度和命令分发。定位算法单独位于 `lib/matcher.cs`，不修改 QTE 判据。

```powershell
npm run check
npm test
npm run test:cursor # 可选：每个显示器四角+中心，只移动鼠标，最后恢复原位
```

普通测试包含真实 PowerShell 5.1/C# 编译、跨进程 JSON 协议、代码指纹一致性、窗口移动/裁剪、模板匹配、停止/重连和模拟 QTE/急停；不向桌面发键鼠输入。光标测试须在有桌面输入权限的终端运行。

设计与验收说明：[定位实现方案](docs/positioning-implementation.md)。原始需求记录：[positioning-redesign.md](docs/positioning-redesign.md)。
