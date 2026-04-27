import SwiftUI

struct TextReplacementSettingsPage: View {
    private struct RuleDraft: Identifiable {
        let id: UUID
        var find: String
        var replace: String
        var scope: TextReplacementScope
        var isEnabled: Bool
        let isBuiltIn: Bool

        init(from rule: TextReplacementRule) {
            self.id = rule.id
            self.find = rule.find
            self.replace = rule.replace
            self.scope = rule.scope
            self.isEnabled = rule.isEnabled
            self.isBuiltIn = ProSettings.builtInRuleIDs.contains(rule.id)
        }

        func toRule() -> TextReplacementRule {
            TextReplacementRule(id: id, find: find, replace: replace, scope: scope, isEnabled: isEnabled)
        }
    }

    @State private var drafts: [RuleDraft]
    @State private var isEditing = false
    @State private var isKeyboardVisible = false
    @Environment(\.dismiss) private var dismiss

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    init() {
        _drafts = State(initialValue: ProSettings.textReplacementRules().map { RuleDraft(from: $0) })
    }

    var body: some View {
        pageContent
#if os(iOS)
            .navigationTitle("Text Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isKeyboardVisible {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditing.toggle()
                            }
                        }
                        .disabled(drafts.allSatisfy(\.isBuiltIn) && !isEditing)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
#endif
    }

    @ViewBuilder
    private var pageContent: some View {
#if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rulesCard
            }
            .padding()
            .padding(.top, 44)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            MacFloatingCircleButton(
                systemImage: "chevron.left",
                help: localized("Back"),
                accessibilityLabel: localized("Back"),
                action: { dismiss() }
            )
            .padding(.top, 10)
            .padding(.leading, 10)
        }
#else
        Form {
            Section {
                ForEach($drafts) { $draft in
                    ruleRow(draft: $draft)
                }

                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                }
                .tint(.red)
            } header: {
                Text("Rules")
            } footer: {
                Text("Each rule replaces all exact occurrences of the \"Find\" text in the selected fields before scrobbling. All keywords are case-sensitive.")
            }
        }
#endif
    }

#if os(macOS)
    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localized("Text Replacement"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label(localized("Add Rule"), systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            Text(localized("Each rule replaces all exact occurrences of the \"Find\" text in the selected fields before scrobbling. All keywords are case-sensitive."))
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach($drafts) { $draft in
                    ruleRow(draft: $draft)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
#endif

    @ViewBuilder
    private func ruleRow(draft: Binding<RuleDraft>) -> some View {
#if os(macOS)
        let isBuiltIn = draft.wrappedValue.isBuiltIn
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: draft.isEnabled)
                .labelsHidden()
                .onValueChange(of: draft.wrappedValue.isEnabled) { _ in persist() }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(localized("Find"), text: draft.find)
                        .textFieldStyle(.roundedBorder)
                        .allowsHitTesting(!isBuiltIn)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    TextField(isBuiltIn ? localized("Blank") : localized("Replace with"), text: draft.replace)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBuiltIn)
                }

                Picker(selection: draft.scope) {
                    ForEach(TextReplacementScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(isBuiltIn)
                .onValueChange(of: draft.wrappedValue.scope) { _ in persist() }
            }
            .frame(maxWidth: .infinity)

            if !isBuiltIn {
                Button(role: .destructive) {
                    if let idx = drafts.firstIndex(where: { $0.id == draft.wrappedValue.id }) {
                        drafts.remove(at: idx)
                        persist()
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "minus.circle.fill")
                    .hidden()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onValueChange(of: draft.wrappedValue.find) { _ in persist() }
        .onValueChange(of: draft.wrappedValue.replace) { _ in persist() }
#else
        let isBuiltIn = draft.wrappedValue.isBuiltIn
        HStack(alignment: .center, spacing: 12) {
            if isEditing && !isBuiltIn {
                Button {
                    if let idx = drafts.firstIndex(where: { $0.id == draft.wrappedValue.id }) {
                        withAnimation {
                            drafts.remove(at: idx)
                            persist()
                        }
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 51)
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                Toggle("", isOn: draft.isEnabled)
                    .labelsHidden()
                    .scaleEffect(0.85)
                    .frame(width: 51)
                    .onValueChange(of: draft.wrappedValue.isEnabled) { _ in persist() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Find", text: draft.find)
                        .disabled(isBuiltIn)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    TextField(isBuiltIn ? "Blank" : "Replace with", text: draft.replace)
                        .disabled(isBuiltIn)
                }
                .onValueChange(of: draft.wrappedValue.find) { _ in persist() }
                .onValueChange(of: draft.wrappedValue.replace) { _ in persist() }

                Picker("Apply to", selection: draft.scope) {
                    ForEach(TextReplacementScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isBuiltIn)
                .onValueChange(of: draft.wrappedValue.scope) { _ in persist() }
            }
        }
        .padding(.vertical, 4)
#endif
    }

    private func addRule() {
        let newRule = TextReplacementRule(
            id: UUID(),
            find: "",
            replace: "",
            scope: .all
        )
        drafts.append(RuleDraft(from: newRule))
        persist()
    }

    private func persist() {
        ProSettings.setTextReplacementRules(drafts.map { $0.toRule() })
    }
}
