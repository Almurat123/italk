import Foundation
import AgentRuntime
import Contacts

enum PeopleSkills {
    static var keys: [CNKeyDescriptor] { [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                          CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey] as [CNKeyDescriptor] }

    static func contactJSON(_ c: CNContact, full: Bool) -> JSONValue {
        let name = [c.familyName, c.givenName].joined().isEmpty ? c.organizationName : (c.familyName + c.givenName)
        var o: [String: JSONValue] = ["id": .string(c.identifier), "name": .string(name)]
        if !c.nickname.isEmpty { o["nickname"] = .string(c.nickname) }
        if !c.organizationName.isEmpty { o["organization"] = .string(c.organizationName) }
        o["phones"] = .array(c.phoneNumbers.prefix(full ? 6 : 2).map { p in
            .object(["label": .string(CNLabeledValue<NSString>.localizedString(forLabel: p.label ?? "")), "number": .string(p.value.stringValue)])
        })
        if full {
            o["emails"] = .array(c.emailAddresses.prefix(4).map { .string($0.value as String) })
            if let b = c.birthday, let m = b.month, let d = b.day { o["birthday"] = .string("\(m)月\(d)日") }
        }
        return .object(o)
    }

    static let search = FnTool(ToolSpec(name: "contacts_search", description: "按姓名、昵称、单位或电话查找联系人", parameters: [
        "query": ParamSpec(.string, "姓名/昵称/单位/电话", maxLength: 60),
        "details": ParamSpec(.boolean, "包含邮箱和生日", required: false)
    ], permission: .readOnly, capability: .contacts, systemPermission: .contacts, dataClass: .personal)) { a, _ in
        guard let q = a.str("query") else { throw fail("缺少查找内容") }
        let store = CNContactStore()
        var found: [CNContact] = []
        let digits = q.filter(\.isNumber)
        if digits.count >= 4 {
            found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: digits)), keysToFetch: keys)
        }
        if found.isEmpty { found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys) }
        if found.isEmpty {
            // Nickname / organization / reversed Chinese name order: scan (bounded).
            let req = CNContactFetchRequest(keysToFetch: keys)
            var n = 0
            try store.enumerateContacts(with: req) { c, stop in
                n += 1; if n > 5000 { stop.pointee = true }
                if (c.familyName + c.givenName).contains(q) || c.nickname.contains(q) || c.organizationName.contains(q) { found.append(c); if found.count >= 10 { stop.pointee = true } }
            }
        }
        return out(["contacts": .array(found.prefix(10).map { contactJSON($0, full: a.flag("details") == true) })], "找到 \(min(found.count, 10)) 位联系人")
    }

    static let create = FnTool(ToolSpec(name: "contacts_create", description: "新建联系人（需要用户确认）", parameters: [
        "givenName": ParamSpec(.string, "名", maxLength: 40),
        "familyName": ParamSpec(.string, "姓", required: false, maxLength: 40),
        "phone": ParamSpec(.string, "电话", required: false, maxLength: 30),
        "email": ParamSpec(.string, "邮箱", required: false, maxLength: 80),
        "organization": ParamSpec(.string, "单位", required: false, maxLength: 80)
    ], permission: .confirmBeforeAction, capability: .contacts, systemPermission: .contacts, dataClass: .personal),
    describe: { a in "新建联系人「\(a.str("familyName") ?? "")\(a.str("givenName") ?? "")」\(a.str("phone").map { "，电话 \($0)" } ?? "")" },
    reconcile: { key in
        guard let id = await IdempotencyMap.shared.get(key), let c = try? CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: keys) else { return nil }
        return out(["contact": contactJSON(c, full: true)], "联系人已存在（恢复后核对）", id: id)
    }) { a, ctx in
        let store = CNContactStore()
        if let id = await IdempotencyMap.shared.get(ctx.idempotencyKey), let c = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) {
            return out(["contact": contactJSON(c, full: true)], "联系人已创建", id: id)
        }
        guard let given = a.str("givenName") else { throw fail("缺少名字") }
        let c = CNMutableContact()
        c.givenName = given; c.familyName = a.str("familyName") ?? ""; c.organizationName = a.str("organization") ?? ""
        if let p = a.str("phone") { c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: p))] }
        if let e = a.str("email") { c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: e as NSString)] }
        let save = CNSaveRequest(); save.add(c, toContainerWithIdentifier: nil)
        try store.execute(save)
        await IdempotencyMap.shared.set(ctx.idempotencyKey, c.identifier)
        return out(["contact": contactJSON(c, full: true)], "已新建联系人「\(c.familyName)\(c.givenName)」", id: c.identifier)
    }

    static func message(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "message_compose", description: "给别人发短信/iMessage：打开编辑界面并填好收件人和内容，由用户亲自点发送。用户说“发短信/发消息给某人”时用它", parameters: [
            "recipients": ParamSpec(.array, "电话号码或邮箱（先用 contacts_search 查到）"),
            "body": ParamSpec(.string, "内容", maxLength: 1000)
        ], permission: .lowRiskAction, capability: .communication, dataClass: .personal, timeoutSeconds: 600)) { a, _ in
            let result = await ctx.presenter.composeMessage(recipients: a.strings("recipients"), body: a.str("body") ?? "")
            let text = ["sent": "用户已发送", "cancelled": "用户取消了发送", "unavailable": "此设备不能发送短信"][result] ?? "发送失败"
            return out(["result": .string(result)], text)
        }
    }

    static func mail(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "mail_compose", description: "打开邮件编辑界面并填好收件人、主题和正文；由用户亲自发送", parameters: [
            "to": ParamSpec(.array, "收件人邮箱"),
            "subject": ParamSpec(.string, "主题", maxLength: 200),
            "body": ParamSpec(.string, "正文", maxLength: 5000)
        ], permission: .lowRiskAction, capability: .communication, dataClass: .personal, timeoutSeconds: 900)) { a, _ in
            let result = await ctx.presenter.composeMail(to: a.strings("to"), subject: a.str("subject") ?? "", body: a.str("body") ?? "")
            return out(["result": .string(result)], ["sent": "邮件已发送", "cancelled": "用户取消了邮件", "unavailable": "未设置邮件账户"][result] ?? "邮件未发送")
        }
    }

    static func call(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "phone_call", description: "拨打电话或 FaceTime（需要用户确认；系统还会再次确认）", parameters: [
            "number": ParamSpec(.string, "电话号码或 FaceTime 账号", maxLength: 40),
            "facetime": ParamSpec(.boolean, "使用 FaceTime", required: false),
            "audioOnly": ParamSpec(.boolean, "FaceTime 语音", required: false)
        ], permission: .confirmBeforeAction, capability: .communication, dataClass: .personal),
        describe: { a in "\(a.flag("facetime") == true ? "FaceTime" : "拨打电话") \(a.str("number") ?? "")" }) { a, _ in
            guard let raw = a.str("number") else { throw fail("缺少号码") }
            let n = raw.filter { $0.isNumber || $0 == "+" || $0 == "@" || $0 == "." || $0.isLetter }
            let scheme = a.flag("facetime") == true ? (a.flag("audioOnly") == true ? "facetime-audio" : "facetime") : "tel"
            guard let url = URL(string: "\(scheme):\(n)") else { throw fail("号码无效") }
            let ok = await ctx.presenter.open(url)
            return out(["started": .bool(ok)], ok ? "已发起呼叫" : "无法发起呼叫")
        }
    }
}
