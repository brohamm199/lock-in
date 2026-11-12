import SwiftUI

/// Grid of all cover templates, previewed live with this session's photo and stats.
struct CoverStylePicker: View {
    let session: FocusSession
    let streak: Int
    let onSave: (CoverTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var context: CoverContext?
    @State private var selection: CoverTemplate

    private let scale: CGFloat = 0.3

    init(session: FocusSession, streak: Int, onSave: @escaping (CoverTemplate) -> Void) {
        self.session = session
        self.streak = streak
        self.onSave = onSave
        _selection = State(initialValue: session.template)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let context {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: CoverSize.width * scale), spacing: 12)], spacing: 18) {
                        ForEach(CoverTemplate.allCases) { template in
                            Button {
                                selection = template
                            } label: {
                                VStack(spacing: 6) {
                                    CoverView(template: template, context: context)
                                        .scaleEffect(scale, anchor: .topLeading)
                                        .frame(width: CoverSize.width * scale, height: CoverSize.height * scale, alignment: .topLeading)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(
                                                    selection == template ? Theme.accent : Color.white.opacity(0.15),
                                                    lineWidth: selection == template ? 3 : 1
                                                )
                                        )
                                    Text(template.name)
                                        .font(.caption.weight(selection == template ? .bold : .regular))
                                        .foregroundStyle(selection == template ? Theme.accent : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                } else {
                    ProgressView()
                        .padding(.top, 120)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Cover style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use style") {
                        onSave(selection)
                        dismiss()
                    }
                    .disabled(context == nil)
                }
            }
            .task {
                context = await RecapBuilder.makeContext(for: session, streak: session.streakAtEnd ?? streak)
            }
        }
    }
}
