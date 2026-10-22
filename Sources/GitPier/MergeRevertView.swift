import GitPierCore
import SwiftUI

/// Part of the existing confirmation ScrollView; no additional sheet or write path.
struct MergeRevertParentPicker: View {
  @ObservedObject var model: RepositoryModel
  let parents: [CommitRecord]
  @EnvironmentObject var store: AppStore
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(store.text("Mainline parent", "主线父提交")).font(.headline)
      Text(store.text("Parent numbers follow Git's commit order. Choose the history to keep as the reference; branch names are not inferred.",
        "父提交编号遵循 Git 的提交顺序。请选择作为参照保留的历史，不会根据分支名自动推断。"))
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      ForEach(Array(parents.enumerated()), id: \.offset) { index, parent in
        let number = index + 1
        let selected = model.confirmation?.mainlineParent == number
        Button { model.confirmation?.mainlineParent = number } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(store.text("Parent \(number)", "父提交 \(number)") + " · " + parent.subject)
                .font(.callout).lineLimit(2).help(parent.subject)
              Text(parent.hash).font(.caption.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05)))
        }.buttonStyle(.plain)
          .accessibilityLabel(store.text("Parent \(number)", "父提交 \(number)") + ": " + parent.subject + "\n" + parent.hash)
          .accessibilityValue(selected ? store.text("Selected", "已选择") : store.text("Not selected", "未选择"))
          .accessibilityIdentifier("gitpier.revert.parent.\(number)")
      }
    }
  }
}
