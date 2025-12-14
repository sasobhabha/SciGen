// SciGenApp.swift - COMPLETE SINGLE FILE APP
import SwiftUI
internal import Combine

// MARK: - DATA MODELS
struct ScienceProblem: Identifiable {
    let id = UUID()
    let question: String
    let options: [String]
    let correctAnswer: Int
    let explanation: String
    let topic: Topic
    let difficulty: Int
    
    enum Topic: String, CaseIterable {
        case biology = "Biology"
        case chemistry = "Chemistry"
        case physics = "Physics"
        case earth = "Earth Science"
        case astronomy = "Astronomy"
        case environmental = "Environmental"
        
        var icon: String {
            switch self {
            case .biology: return "leaf.fill"
            case .chemistry: return "testtube.2"
            case .physics: return "atom"
            case .earth: return "globe.europe.africa.fill"
            case .astronomy: return "sparkles"
            case .environmental: return "leaf.arrow.triangle.circlepath"
            }
        }
        
        var color: Color {
            switch self {
            case .biology: return .green
            case .chemistry: return .blue
            case .physics: return .purple
            case .earth: return .brown
            case .astronomy: return .indigo
            case .environmental: return .teal
            }
        }
    }
}

struct UserStats {
    var correct: Int = 0
    var total: Int = 0
    var streak: Int = 0
    var bestStreak: Int = 0
    var accuracy: Double { total > 0 ? Double(correct) / Double(total) : 0 }
}

// MARK: - MAIN APP
@main
struct SciGenApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
    }
}

// MARK: - APP STATE (REAL API ONLY)
class AppState: ObservableObject {
    @Published var currentProblem: ScienceProblem?
    @Published var selectedTopics: Set<ScienceProblem.Topic> = [.biology, .chemistry, .physics]
    @Published var difficulty: Double = 5.0
    @Published var stats = UserStats()
    @Published var isLoading = false
    @Published var showSolution = false
    @Published var selectedAnswer: Int?
    @Published var errorMessage: String?
    
    private let apiURL = "https://api.groq.com/openai/v1/chat/completions"
    private let groqBaseURL = "https://api.groq.com/openai/v1"
    private let groqAPIKey: String
    
    init() {
        // Get API key from Info.plist or environment
        if let key = Bundle.main.infoDictionary?["GROQ_API_KEY"] as? String {
            self.groqAPIKey = key
        } else if let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"] {
            self.groqAPIKey = key
        } else {
            fatalError("GROQ_API_KEY not found in Info.plist or environment")
        }
    }
    
    func generateProblem() async {
        guard !selectedTopics.isEmpty else {
            errorMessage = "Please select at least one topic"
            return
        }
        
        isLoading = true
        selectedAnswer = nil
        showSolution = false
        errorMessage = nil
        
        do {
            let topic = Array(selectedTopics).randomElement() ?? .biology
            let problem = try await generateRealAIProblem(topic: topic, difficulty: Int(difficulty))
            
            await MainActor.run {
                currentProblem = problem
                isLoading = false
                stats.total += 1
                
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = "API Error: \(error.localizedDescription)"
                print("API Failed: \(error)")
            }
        }
    }
    
    private func generateRealAIProblem(topic: ScienceProblem.Topic, difficulty: Int) async throws -> ScienceProblem {
        let systemPrompt = """
        CRITICAL: Return ONLY valid JSON. No other text.
        
        Generate one multiple-choice science question about \(topic.rawValue).
        Difficulty level: \(difficulty)/10.
        
        Required JSON format:
        {
          "question": "Your science question here?",
          "options": ["Option A text", "Option B text", "Option C text", "Option D text"],
          "correctAnswer": 0,
          "explanation": "Detailed explanation here..."
        }
        
        Rules:
        1. correctAnswer must be 0, 1, 2, or 3
        2. Provide 4 distinct options
        3. Explanation should teach the concept
        4. Make it challenging but fair for difficulty \(difficulty)
        """
        
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate exactly one science question in JSON format."]
            ],
            "temperature": 0.7,
            "max_tokens": 800,
            "response_format": ["type": "json_object"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "API Error \(httpResponse.statusCode): \(errorText)"])
        }
        
        let apiResponse = try JSONDecoder().decode(GroqAPIResponse.self, from: data)
        
        guard let jsonString = apiResponse.choices.first?.message.content,
              let jsonData = jsonString.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        let problemData = try JSONDecoder().decode(AIProblemData.self, from: jsonData)
        
        // Validate the response
        guard problemData.options.count == 4 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "API returned \(problemData.options.count) options, expected 4"])
        }
        
        guard (0...3).contains(problemData.correctAnswer) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Invalid correctAnswer: \(problemData.correctAnswer)"])
        }
        
        return ScienceProblem(
            question: problemData.question.trimmingCharacters(in: .whitespacesAndNewlines),
            options: problemData.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            correctAnswer: problemData.correctAnswer,
            explanation: problemData.explanation.trimmingCharacters(in: .whitespacesAndNewlines),
            topic: topic,
            difficulty: difficulty
        )
    }
    
    func checkAnswer() {
        guard let problem = currentProblem, let answer = selectedAnswer else { return }
        
        showSolution = true
        let isCorrect = answer == problem.correctAnswer
        
        if isCorrect {
            stats.correct += 1
            stats.streak += 1
            stats.bestStreak = max(stats.bestStreak, stats.streak)
        } else {
            stats.streak = 0
        }
    }
}

// MARK: - API DATA STRUCTURES
struct GroqAPIResponse: Codable {
    let choices: [AIChoice]
    
    struct AIChoice: Codable {
        let message: AIMessage
    }
    
    struct AIMessage: Codable {
        let content: String
    }
}

struct AIProblemData: Codable {
    let question: String
    let options: [String]
    let correctAnswer: Int
    let explanation: String
}
// MARK: - MAIN CONTENT VIEW
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            PracticeView()
                .tabItem {
                    Label("Practice", systemImage: "brain.head.profile")
                }
            
            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
            
            TopicsView()
                .tabItem {
                    Label("Topics", systemImage: "square.grid.2x2.fill")
                }
        }
        .accentColor(.blue)
    }
}

// MARK: - PRACTICE VIEW
struct PracticeView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("SciGen")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.blue)
                    Text("AI Science Practice")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // Problem or Welcome
                if appState.isLoading {
                    LoadingView()
                } else if let problem = appState.currentProblem {
                    ProblemCard(problem: problem)
                } else {
                    WelcomeCard()
                }
                
                // Topics
                TopicGrid()
                
                // Difficulty
                DifficultySlider()
                
                // Stats
                StatsGrid()
                
                // Actions
                ActionButtons()
            }
            .padding(.vertical)
        }
        .navigationTitle("Practice")
    }
}

// MARK: - SUBVIEWS
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("AI is generating your problem...")
                .foregroundColor(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }
}

struct WelcomeCard: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 70))
                .foregroundColor(.blue)
            
            VStack(spacing: 10) {
                Text("Welcome to SciGen!")
                    .font(.title2)
                    .bold()
                
                Text("Select topics and tap Generate to start")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.1), radius: 10)
        .padding(.horizontal)
    }
}

struct ProblemCard: View {
    let problem: ScienceProblem
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            // Question
            Text(problem.question)
                .font(.title2)
                .bold()
                .fixedSize(horizontal: false, vertical: true)
            
            // Options
            ForEach(Array(problem.options.enumerated()), id: \.offset) { index, option in
                Button(action: {
                    if !appState.showSolution {
                        appState.selectedAnswer = index
                    }
                }) {
                    HStack(spacing: 15) {
                        // Letter
                        Text(["A", "B", "C", "D"][index])
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(letterBackground(for: index))
                            .foregroundColor(letterForeground(for: index))
                            .cornerRadius(10)
                        
                        // Text
                        Text(option)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        
                        Spacer()
                        
                        // Status Icon
                        if appState.showSolution {
                            if index == problem.correctAnswer {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else if index == appState.selectedAnswer {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding()
                    .background(optionBackground(for: index))
                    .cornerRadius(15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(optionBorder(for: index), lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Solution
            if appState.showSolution {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Image(systemName: appState.selectedAnswer == problem.correctAnswer ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.selectedAnswer == problem.correctAnswer ? .green : .red)
                        Text(appState.selectedAnswer == problem.correctAnswer ? "Correct!" : "Incorrect")
                            .font(.headline)
                            .foregroundColor(appState.selectedAnswer == problem.correctAnswer ? .green : .red)
                    }
                    
                    Text("Explanation:")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text(problem.explanation)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(15)
            }
            
            // Problem Info
            HStack {
                HStack {
                    Image(systemName: problem.topic.icon)
                        .foregroundColor(problem.topic.color)
                    Text(problem.topic.rawValue)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(problem.topic.color.opacity(0.2))
                .cornerRadius(15)
                
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("Level \(problem.difficulty)/10")
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.2))
                .cornerRadius(15)
                
                Spacer()
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.1), radius: 10)
        .padding(.horizontal)
    }
    
    private func letterBackground(for index: Int) -> Color {
        if appState.showSolution {
            if index == problem.correctAnswer { return .green }
            if index == appState.selectedAnswer { return .red }
        }
        return appState.selectedAnswer == index ? .blue : .gray.opacity(0.3)
    }
    
    private func letterForeground(for index: Int) -> Color {
        if appState.showSolution {
            if index == problem.correctAnswer || index == appState.selectedAnswer { return .white }
        }
        return appState.selectedAnswer == index ? .white : .primary
    }
    
    private func optionBackground(for index: Int) -> Color {
        if appState.showSolution {
            if index == problem.correctAnswer { return .green.opacity(0.1) }
            if index == appState.selectedAnswer { return .red.opacity(0.1) }
        }
        return appState.selectedAnswer == index ? .blue.opacity(0.1) : Color(.secondarySystemBackground)
    }
    
    private func optionBorder(for index: Int) -> Color {
        if appState.showSolution {
            if index == problem.correctAnswer { return .green }
            if index == appState.selectedAnswer { return .red }
        }
        return appState.selectedAnswer == index ? .blue : .clear
    }
}

struct TopicGrid: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Topics")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ScienceProblem.Topic.allCases, id: \.self) { topic in
                        Button(action: {
                            if appState.selectedTopics.contains(topic) {
                                appState.selectedTopics.remove(topic)
                            } else {
                                appState.selectedTopics.insert(topic)
                            }
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: topic.icon)
                                    .font(.title2)
                                    .foregroundColor(topic.color)
                                Text(topic.rawValue.components(separatedBy: " ").first ?? "")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.primary)
                            }
                            .frame(width: 80, height: 80)
                            .background(
                                appState.selectedTopics.contains(topic) ?
                                topic.color.opacity(0.2) : Color.gray.opacity(0.1)
                            )
                            .cornerRadius(15)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(
                                        appState.selectedTopics.contains(topic) ?
                                        topic.color : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct DifficultySlider: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Difficulty Level")
                    .font(.headline)
                Spacer()
                Text("\(Int(appState.difficulty))/10")
                    .font(.title3)
                    .bold()
                    .foregroundColor(difficultyColor)
            }
            
            Slider(value: $appState.difficulty, in: 1...10, step: 1)
                .accentColor(difficultyColor)
            
            HStack {
                Text("Easy")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Expert")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(15)
        .shadow(color: .black.opacity(0.05), radius: 5)
        .padding(.horizontal)
    }
    
    private var difficultyColor: Color {
        switch appState.difficulty {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        case 9...10: return .red
        default: return .blue
        }
    }
}

struct StatsGrid: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 15) {
            StatItem(value: "\(appState.stats.correct)", label: "Correct")
            StatItem(value: "\(appState.stats.total)", label: "Total")
            StatItem(value: "\(Int(appState.stats.accuracy * 100))%", label: "Accuracy")
            StatItem(value: "\(appState.stats.streak)", label: "Streak")
        }
        .padding(.horizontal)
    }
}

struct StatItem: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack {
            Text(value)
                .font(.title2)
                .bold()
                .foregroundColor(.blue)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

struct ActionButtons: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 15) {
            // Generate Button
            Button(action: {
                Task {
                    await appState.generateProblem()
                }
            }) {
                HStack {
                    if appState.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Generate AI Problem")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                )
                .foregroundColor(.white)
                .cornerRadius(15)
            }
            .disabled(appState.selectedTopics.isEmpty || appState.isLoading)
            
            // Control Buttons
            HStack(spacing: 15) {
                Button(action: {
                    appState.checkAnswer()
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Check Answer")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(appState.currentProblem == nil ||
                         appState.selectedAnswer == nil ||
                         appState.showSolution)
                
                Button(action: {
                    Task {
                        await appState.generateProblem()
                    }
                }) {
                    HStack {
                        Image(systemName: "forward.fill")
                        Text("Next Problem")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(appState.isLoading)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - STATS VIEW
struct StatsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                Text("Statistics")
                    .font(.largeTitle)
                    .bold()
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 20) {
                    StatCard(title: "Total Problems", value: "\(appState.stats.total)", icon: "number.circle", color: .blue)
                    StatCard(title: "Correct Answers", value: "\(appState.stats.correct)", icon: "checkmark.circle", color: .green)
                    StatCard(title: "Accuracy", value: "\(Int(appState.stats.accuracy * 100))%", icon: "chart.line.uptrend.xyaxis", color: .purple)
                    StatCard(title: "Current Streak", value: "\(appState.stats.streak)", icon: "flame", color: .orange)
                    StatCard(title: "Best Streak", value: "\(appState.stats.bestStreak)", icon: "trophy", color: .yellow)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 34, weight: .bold))
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(15)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
}

// MARK: - TOPICS VIEW
struct TopicsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Selected Topics") {
                ForEach(ScienceProblem.Topic.allCases, id: \.self) { topic in
                    Toggle(topic.rawValue, isOn: Binding(
                        get: { appState.selectedTopics.contains(topic) },
                        set: { isOn in
                            if isOn {
                                appState.selectedTopics.insert(topic)
                            } else {
                                appState.selectedTopics.remove(topic)
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: topic.color))
                }
            }
            
            Section("Settings") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Difficulty Level: \(Int(appState.difficulty))/10")
                        .font(.headline)
                    Slider(value: $appState.difficulty, in: 1...10, step: 1)
                }
                .padding(.vertical, 5)
                
                Button("Reset Statistics") {
                    appState.stats = UserStats()
                }
                .foregroundColor(.red)
            }
            
            Section("About") {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("SciGen v1.0")
                            .bold()
                        Text("AI Science Practice Platform")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Topics & Settings")
    }
}

