import SwiftUI

struct LumiInterface: View {
    @ObservedObject private var core = AeonCore.shared
    @State private var userInput: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("🤖 Lumi AI")
                .font(.largeTitle)
                .bold()
                .padding(.top)
            
            Text("Emotion: \(core.emotionalState)")
                .font(.headline)
                .foregroundColor(.gray)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(core.contextMemory.suffix(10), id: \.self) { entry in
                        Text("• \(entry)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            TextField("Type your message…", text: $userInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
            
            Button(action: {
                LumiApp.shared.handleInput(userInput)
                userInput = ""
            }) {
                Text("Send to Lumi")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    LumiInterface()
}
