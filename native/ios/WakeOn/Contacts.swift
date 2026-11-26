import Contacts
import CryptoKit
import UIKit
import UserNotifications

/// Pixie's contacts tool: find someone in the iPhone's contacts and, once the user says yes,
/// hang up and start a phone or FaceTime call to them. Optional: Settings › Pixie can turn it
/// off, and iOS asks for access the first time it's used (only with Pixie on screen).
///
/// Phone numbers never go to OpenAI: Pixie sees names, labels ("mobile") and an id per
/// number, and the app looks the number up again from the id. iOS confirms every phone call.
enum PixieContacts {
    static let toolName = "contacts"
    static let enabledKey = "contacts.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Find people in the user's iPhone contacts, or start a phone or FaceTime call to one of their numbers.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["search", "call"]],
                "query": ["type": "string", "description": "search: a name or part of one (\"Sam\", \"Dr. Lee\", \"Mom\"). Otherwise empty."],
                "id": ["type": "string", "description": "call: the number's id from search. Otherwise empty."],
                "method": ["type": "string", "enum": ["phone", "facetime", "facetime_audio"],
                           "description": "call: how to call; phone unless the user asks for FaceTime."],
            ] as [String: Any],
            "required": ["action", "query", "id", "method"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user wants to call or reach someone, or asks about a contact, call contacts with \
    action search and their name. Say who you found by name and label ("Sam Lee, mobile"), never \
    the number, and if several match ask which one. Before calling, ask "Want me to call them?" \
    and only call contacts with action call after the user says yes in this call. Calling ends \
    this conversation.
    """

    static let deniedText = "The user hasn't allowed Pixie to use their contacts. Ask them to turn it on in the iPhone's Settings › Pixie › Contacts."
    static let backgroundText = "Pixie can only ask for access to contacts while it's open on screen. Ask the user to open Pixie and ask again."
    static let unknownIDText = "No number with that id. Search again first."

    /// A number Pixie may call, by id.
    struct Number: Equatable {
        let name: String
        let label: String
        let digits: String
    }

    /// The call the app makes once the conversation hangs up.
    struct Call: Equatable {
        let name: String
        let label: String
        let url: URL
    }

    /// "+1 (416) 555-0199" → "+14165550199". Nil if there's nothing to dial.
    static func dialable(_ number: String) -> String? {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed.filter { $0.isASCII && ($0.isNumber || $0 == "*" || $0 == "#") })
        guard rest.contains(where: \.isNumber) else { return nil }
        return (trimmed.hasPrefix("+") ? "+" : "") + rest
    }

    static func url(for digits: String, method: String) -> URL? {
        switch method {
        case "facetime": URL(string: "facetime://\(digits)")
        case "facetime_audio": URL(string: "facetime-audio://\(digits)")
        default: URL(string: "tel://\(digits)")
        }
    }

    /// "mobile" from "_$!<Mobile>!$_", or the custom label as is.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "phone" }
        return CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: raw).lowercased()
    }

    /// The same six characters for the same number in every search.
    static func shortID(_ contact: String, _ number: String) -> String {
        SHA256.hash(data: Data("\(contact)|\(number)".utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// Search results as Pixie reads them: names, labels and ids, no numbers.
    static func describe(_ people: [(name: String, numbers: [(id: String, label: String)])], query: String) -> String {
        guard !people.isEmpty else { return "No contacts match \"\(query)\". Ask the user for the name as it's saved." }
        let lines = people.prefix(8).map { person -> String in
            let numbers = person.numbers.isEmpty ? "no phone number"
                : person.numbers.map { "\($0.label) (id \($0.id))" }.joined(separator: ", ")
            return "- \(person.name): \(numbers)"
        }
        let more = people.count > 8 ? "\n(\(people.count - 8) more; ask the user to be more specific.)" : ""
        return "Contacts matching \"\(query)\":\n" + lines.joined(separator: "\n") + more
    }

    /// Opens the call. In the background the app can't, so it posts a notification to tap.
    @MainActor
    static func place(_ call: Call, done: (@MainActor (String) -> Void)? = nil) {
        guard UIApplication.shared.applicationState == .active else {
            let content = UNMutableNotificationContent()
            content.title = "Call \(call.name)"
            content.body = "Tap to call \(call.name) (\(call.label))."
            content.userInfo = ["callURL": call.url.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "contact-call", content: content, trigger: nil))
            VoiceSessionController.appLog("contact_call_notification")
            done?("notification")
            return
        }
        UIApplication.shared.open(call.url) { opened in
            VoiceSessionController.appLog("contact_call_open scheme=\(call.url.scheme ?? "") opened=\(opened)")
            done?(opened ? "opened" : "failed")
        }
    }
}

/// One CNContactStore for the app, and the numbers Pixie was shown in its last searches.
@MainActor
final class ContactBook {
    static let shared = ContactBook()
    private let store = CNContactStore()
    private var shown: [String: PixieContacts.Number] = [:]

    /// The tool's output, and the call to make after hanging up (for action call).
    func perform(_ args: [String: Any]) async -> (result: String, call: PixieContacts.Call?) {
        if let problem = await access() { return (problem, nil) }
        switch args["action"] as? String ?? "" {
        case "search":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return ("Say whose contact to look for.", nil) }
            return (search(query), nil)
        case "call":
            guard let number = shown[args["id"] as? String ?? ""] else { return (PixieContacts.unknownIDText, nil) }
            let method = args["method"] as? String ?? "phone"
            guard let url = PixieContacts.url(for: number.digits, method: method) else { return (PixieContacts.unknownIDText, nil) }
            let how = method == "phone" ? "" : " on FaceTime"
            return ("Calling \(number.name) (\(number.label))\(how); this conversation is ending. Say so in a few words.",
                    PixieContacts.Call(name: number.name, label: number.label, url: url))
        default:
            return ("Unknown action: use search or call.", nil)
        }
    }

    private func search(_ query: String) -> String {
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactNicknameKey as CNKeyDescriptor,
                                       CNContactOrganizationNameKey as CNKeyDescriptor]
        var found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
        if found.isEmpty {
            // Nicknames and companies ("Mom", "Dentist") aren't part of the name search.
            let request = CNContactFetchRequest(keysToFetch: keys)
            let needle = query.lowercased()
            try? store.enumerateContacts(with: request) { contact, stop in
                if contact.nickname.lowercased().contains(needle) || contact.organizationName.lowercased().contains(needle) {
                    found.append(contact)
                    if found.count >= 20 { stop.pointee = true }
                }
            }
        }
        let people = found.map { contact -> (name: String, numbers: [(id: String, label: String)]) in
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? (contact.organizationName.isEmpty ? contact.nickname : contact.organizationName)
            let numbers = contact.phoneNumbers.compactMap { entry -> (id: String, label: String)? in
                guard let digits = PixieContacts.dialable(entry.value.stringValue) else { return nil }
                let id = PixieContacts.shortID(contact.identifier, digits)
                let label = PixieContacts.label(entry.label)
                shown[id] = PixieContacts.Number(name: name, label: label, digits: digits)
                return (id, label)
            }
            return (name, numbers)
        }
        VoiceSessionController.appLog("contacts_search matches=\(people.count)")
        return PixieContacts.describe(people, query: query)
    }

    private func access() async -> String? {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return nil
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else { return PixieContacts.backgroundText }
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            return granted ? nil : PixieContacts.deniedText
        default: return PixieContacts.deniedText
        }
    }
}
