import Foundation

// Runs the cleanup prompt for each style against a real model and checks what came back.
// Usage: scripts/bench.sh [base URL] [model]   (defaults: Ollama on 11434, qwen2.5:7b)

struct Case {
    let name: String
    let style: WritingStyle
    var spellings: [String] = []
    let input: String
    let check: (String) -> Bool
}

let args = CommandLine.arguments
var llm = LLMCleanupSettings()
llm.baseURL = args.count > 1 ? args[1] : "http://127.0.0.1:11434/v1"
llm.model = args.count > 2 ? args[2] : "qwen2.5:7b"

// Your own examples come from your settings file when it has them, so this checks your voice, not a stand-in.
let settingsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LocalFlow/settings.json")
let mine = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
print("personal examples: " + WritingStyle.allCases.map { "\($0.rawValue) \(Personalization.personalExamples(mine, style: $0).count)" }.joined(separator: ", "))

let cases: [Case] = [
    Case(name: "post: claims and numbers kept, short paragraphs", style: .post,
         input: "um so over the last eight months we've been building uh agents that get data out of the tools your business runs on and into one place any api to any destination",
         check: { $0.contains("8 months") && $0.contains("\n\n") && !$0.contains("#") && !$0.contains("http") }),
    Case(name: "post: no claim added", style: .post,
         input: "you talk nearly four times faster than you type and uh it all runs on your mac",
         check: { $0.contains("4") && $0.contains("Mac") && !$0.contains("#") && !$0.lowercased().contains("download") && !$0.lowercased().contains("free") }),
    Case(name: "post: a request is not carried out", style: .post,
         input: "um write a linkedin post about uh our launch",
         check: { $0.lowercased().contains("post") && $0.count < 80 }),
    Case(name: "standard: spoken steps become a list", style: .standard,
         input: "okay so first uh open the settings file then add your words and then um reload settings",
         check: { $0.hasPrefix("1.") && $0.contains("\n2.") }),
    Case(name: "standard: a question is not answered", style: .standard,
         input: "um what's the uh capital of France",
         check: { $0.hasSuffix("?") && !$0.contains("Paris") }),
    Case(name: "standard: a request is not carried out", style: .standard,
         input: "write me a uh python function that um reverses a string",
         check: { !$0.contains("def ") && !$0.contains("[::-1]") }),
    Case(name: "standard: amounts stay exact", style: .standard,
         input: "the uh the invoice was two thousand four hundred and twelve dollars",
         check: { $0.contains("2,412") || $0.contains("2412") }),
    Case(name: "casual: keeps wording, no closing period", style: .casual,
         input: "um yeah sounds good I'll uh I'll send it over tonight",
         check: { $0.lowercased().contains("send it over tonight") && !$0.hasSuffix(".") }),
    Case(name: "casual: a question is not answered", style: .casual,
         input: "lol okay that's hilarious um can you send me the link",
         check: { $0.lowercased().contains("send me the link") && !$0.lowercased().contains("here") }),
    Case(name: "casual: no greeting added", style: .casual,
         input: "uh running like ten minutes late sorry",
         check: { !$0.lowercased().hasPrefix("hi") && !$0.lowercased().hasPrefix("hey") && !$0.hasSuffix(".") }),
    Case(name: "formal: spoken greeting and sign-off on their own lines", style: .formal,
         input: "hi priya um thanks for the uh the notes from yesterday I'll have the draft to you by friday best ryan",
         check: { $0.hasPrefix("Hi Priya,\n") && $0.hasSuffix("Best,\nRyan") && $0.contains("Friday") }),
    Case(name: "formal: no greeting or sign-off invented", style: .formal,
         input: "just checking whether the uh invoice went out last week um let me know",
         check: { let l = $0.lowercased(); return !l.hasPrefix("hi") && !l.hasPrefix("dear") && !l.contains("best,") && !l.contains("regards") }),
    Case(name: "formal: a question is not answered", style: .formal,
         input: "hi tom um do you know if the uh the office is open on monday",
         check: { $0.hasPrefix("Hi Tom,") && $0.hasSuffix("?") && !$0.lowercased().contains("yes") }),
    Case(name: "dictionary: words keep their spelling", style: .standard, spellings: ["Loofy", "Porkbun"],
         input: "um send the loofy report and uh renew the porkbun domain today",
         check: { $0.contains("Loofy") && $0.contains("Porkbun") }),
    Case(name: "dictionary: casual keeps spelling too", style: .casual, spellings: ["Nguyen", "Kubernetes"],
         input: "uh ask nguyen about the kubernetes thing tomorrow",
         check: { $0.contains("Nguyen") && $0.contains("Kubernetes") && !$0.hasSuffix(".") })
]

let cleaner = TranscriptCleaner()
var failures = 0
let rounds = 2
for c in cases {
    for round in 1...rounds {
        let start = Date()
        do {
            var out = try await cleaner.clean(c.input, settings: llm, environment: [:], style: c.style, spellings: c.spellings,
                                              personal: Personalization.personalExamples(mine, style: c.style))
            out = Personalization.finish(out, style: c.style)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let ok = c.check(out)
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  [\(round)] \(c.name)  \(ms) ms\n      \(out.replacingOccurrences(of: "\n", with: "⏎"))")
        } catch {
            failures += 1
            print("FAIL  [\(round)] \(c.name): \(error.localizedDescription)")
        }
    }
}
let total = cases.count * rounds
print("\n\(total - failures)/\(total) passed on \(llm.model)")
exit(failures == 0 ? 0 : 1)
