---
name: interactive-ui
description: Compose native visual explanations, charts, comparisons and local-only controls in iTalk answers.
version: 1.0.0
tags: [interface, visualization]
---

# iTalk interface on a remote task

The following component vocabulary is shared with iTalk on the phone. A send or tool action creates a visible follow-up task on this same computer. It does not execute the requested tool directly; the normal permissions and approvals still apply.

用途：当纯文字不够好用时，在回答中生成一个可交互的原生界面。适合：让用户在几个选项中挑选、比较多个方案、用滑块调参数看结果、
展示数据图表、分步计划、表单收集信息、可视化讲解（函数图像、几何示意）。简单问答、闲聊、只需一句话的回答不要用。

写法：在回答正文里放一个代码块，语言标记为 italk-ui，内容是一个 JSON 文档。代码块前后可以有普通文字（简短说明即可，不要重复界面里的内容）。
```italk-ui
{"id":"唯一英文id","title":"可选标题","state":{"初始状态键":值},"root":{组件}}
```
- 必须是合法 JSON（双引号、无注释、无尾逗号）。整个文档不超过约 300 个组件。
- id 用于保存用户的交互状态。以后要更新同一个界面时，使用相同 id 再输出一个新版本，用户已选的值会保留。

组件（每个组件是 {"type": "...", ...}；任何组件都可以加 "visible": "{{表达式}}" 控制显示）：
布局：stack（"direction":"vertical"|"horizontal","spacing":数字,"align":"leading|center|trailing","children":[...]）、row（横向）、
  grid（"columns":2-4,"children"）、card（"title","subtitle","icon","children"，带底色的分组）、section（无底色分组）、scroll（横向滚动）、divider、spacer
展示：text（"value","style":"title|title3|headline|body|subheadline|footnote|caption","weight","tone","align"）、markdown（"value"）、
  math（"latex"）、code（"language","code"）、icon（"name": SF Symbol 名称）、image（"url": 仅 https）、badge（"text","tone"）、
  metric（"label","value","unit","delta","tone"）、progress（"value":0-1,"label"）、keyValue（"items":[{"label","value"}]）、
  list（"items":[{"title","subtitle","icon","trailing","action"}]）、steps（"items":[{"title","detail","done"}]）、
  table（"columns":[...],"rows":[[...]]）、
  chart（"kind":"bar|line|area|point|pie|donut","data":[{"x","y","series"}],"title","xLabel","yLabel","height"）、
  canvas（"width","height","shapes":[{"kind":"circle|rect|line|arrow|text|plot", 坐标 x y r w h x1 y1 x2 y2,"color","text",
    plot 用 "fn":"关于 x 的表达式","from","to","originX","originY","scaleX","scaleY"}]），用于示意图和可视化讲解
输入（"bind" 绑定到 state 里的键）：chips（"options":["A","B"] 或 [{"label","value","icon"}],"multiple":true/false）、
  slider（"label","bind","min","max","step","display"）、stepper、toggle（"label","bind"）、textField（"bind","placeholder","multiline"）、
  picker（"options","bind","style":"segmented|menu"）、button（"label","icon","style":"primary|secondary|plain|destructive","action"）
tone：primary secondary accent success warning danger purple teal

绑定：字符串里的 {{表达式}} 会用当前 state 计算，例如 "{{round(price*qty, 2)}} 元"、"visible":"{{plan == 'B'}}"。
表达式支持数字、'字符串'、state 键（a.b 取子字段，list.length）、+ - * / % ^、== != < <= > >=、&& || !、条件 ? : 、
函数 min max abs sqrt floor ceil round(x,位数) fixed(x,位数) percent(x) pow sin cos tan log exp len sum contains if。
只能读写本界面的 state，不能访问其他数据。

动作（button 的 "action"，或 list 项的 "action"；可以是一个动作或动作数组）：
- {"type":"set","key":"k","value":"{{表达式}}"} 或 {"set":{"k":值}} 改本地状态（立即生效，不发消息）
- {"type":"toggle","key":"k"}、{"type":"reset"}
- {"type":"send","text":"我选择了 {{choice}}"} 把一句话作为用户消息发回对话，你会在下一轮收到并继续回答。用于"确认选择""提交表单"等需要你继续处理的情况。每个发送按钮只能用一次。
- {"type":"tool","tool":"工具名","arguments":{...},"label":"可选：发送给你的请求文字"} 请求执行工具：不会直接执行，而是作为用户请求发回对话，由你按正常流程调用工具，需要确认的操作仍会请用户确认。
- {"type":"open","url":"https://..."}、{"type":"copy","text":"..."}

原则：
- 先判断是否真的需要界面；需要时组合组件表达内容，而不是套用固定模板。复杂度随问题需要：一个选择用 chips，一个比较用 table 或 grid，数量关系用 slider+metric/canvas 让用户亲手调。
- 用户能在界面里完成的计算用表达式直接算出，不要让用户每动一下都发消息；需要你判断、查询或执行工具时才用 send/tool。
- 收到界面发回的消息后，用文字回答；需要时输出同一 id 的新版本界面。
- 不要编造数据。图表和数字必须来自对话或工具结果。
- 界面文字用用户的语言，简短。
示例（贷款计算，用户自己调参数）：
```italk-ui
{"id":"loan","state":{"amount":300000,"years":20,"rate":3.5},"root":{"type":"card","title":"月供计算","children":[
 {"type":"slider","label":"贷款金额","bind":"amount","min":50000,"max":2000000,"step":10000,"display":"{{round(amount/10000)}} 万"},
 {"type":"slider","label":"年限","bind":"years","min":5,"max":30,"step":1,"display":"{{years}} 年"},
 {"type":"slider","label":"年利率","bind":"rate","min":2,"max":6,"step":0.05,"display":"{{fixed(rate,2)}}%"},
 {"type":"metric","label":"每月还款","value":"{{round(amount*(rate/1200)*pow(1+rate/1200,years*12)/(pow(1+rate/1200,years*12)-1))}}","unit":"元"},
 {"type":"button","label":"按这个方案帮我做还款计划","style":"primary","action":{"type":"send","text":"请按贷款 {{amount}} 元、{{years}} 年、年利率 {{rate}}% 给我做还款计划"}}]}}
```
