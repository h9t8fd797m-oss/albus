import Foundation
import AlbusCore

/// The tool library.
///
/// A fixed catalogue rather than anything fetched: every destination is a
/// compile-time constant, so nothing a model wrote or a student typed can
/// become a URL the app opens, and the whole list works offline.
///
/// **On logos.** A tool shows its real logo or it shows nothing. It never shows
/// a colour this app invented for it: Notion is not teal because a palette said
/// so, and a made-up brand colour is the loudest possible tell that nobody
/// checked. `ToolIcon` renders the asset named `logo-<id>` when one is bundled
/// and falls back to a neutral monogram-free placeholder otherwise — so a tool
/// carries no colour of its own, and dropping artwork in later touches no code.
///
/// Runtime favicon fetching was considered and rejected: it would tell two
/// hundred companies when a student opens this tab, cost a request per tile,
/// and leave the screen broken offline. Logos are fetched at build time by
/// `fetch_logos.py` and reviewed by hand.
enum StudyTool: String, CaseIterable, Identifiable, Sendable {
    case claude
    case chatgpt
    case perplexityPro
    case notebooklm
    case gemini
    case consensus
    case elicit
    case scite
    case grammarly
    case hemingwayEditor
    case prowritingaid
    case languagetool
    case quillbot
    case thesaurusCom
    case merriamWebster
    case oxfordLearnerS
    case purdueOwl
    case hemingwayMode
    case notion
    case obsidian
    case googleDocs
    case overleaf
    case scrivener
    case ulysses
    case zotero
    case mendeley
    case endnote
    case citationMachine
    case zoterobib
    case scribbr
    case hemingwayGrade
    case wordcounter
    case onelook
    case googleScholar
    case jstor
    case pubmed
    case arxiv
    case semanticScholar
    case connectedPapers
    case researchgate
    case core
    case doaj
    case sciHubAlternatives
    case unpaywall
    case internetArchive
    case projectGutenberg
    case perplexity
    case wikipedia
    case britannica
    case ourWorldInData
    case statista
    case worldBankData
    case unData
    case eurostat
    case googleDatasetSearch
    case libraryGenesisInfo
    case hathitrust
    case jstorDaily
    case nature
    case science
    case ssrn
    case philpapers
    case historicalAtlas
    case wolframAlpha
    case symbolab
    case desmos
    case geogebra
    case photomath
    case mathway
    case khanAcademy
    case brilliant
    case paulSNotes
    case t3Blue1Brown
    case integralCalculator
    case derivativeCalculator
    case matrixCalculator
    case statisticsKingdom
    case desmosMatrix
    case sagemath
    case numbas
    case projectEuler
    case oeis
    case mathigon
    case phetSimulations
    case chemspider
    case pubchem
    case periodicTable
    case biorender
    case proteinDataBank
    case nasaEarthdata
    case stellariumWeb
    case physicsClassroom
    case hyperphysics
    case anatomyAtlas
    case geneticsHomeRef
    case climateData
    case usgs
    case encyclopediaOfLife
    case foldit
    case labster
    case concordConsortium
    case github
    case replit
    case stackOverflow
    case mdnWebDocs
    case w3Schools
    case leetcode
    case hackerrank
    case codecademy
    case freecodecamp
    case exercism
    case regex101
    case jsonFormatter
    case compilerExplorer
    case devdocs
    case codepen
    case jupyter
    case googleColab
    case kaggle
    case pythonDocs
    case swiftDocs
    case visualStudioCode
    case gitDocs
    case deepl
    case linguee
    case googleTranslate
    case wordreference
    case duolingo
    case anki
    case memrise
    case conjuguemos
    case reversoContext
    case forvo
    case tatoeba
    case lang8Hinative
    case clozemaster
    case readlang
    case forest
    case pomofocus
    case togglTrack
    case coldTurkey
    case freedom
    case noisli
    case brainFm
    case rainyMood
    case lofiGirl
    case focusmate
    case studyTogether
    case habitica
    case streaks
    case sleepCycle
    case quizlet
    case ankiWeb
    case remnote
    case brainscape
    case cram
    case knowt
    case goodnotes
    case notability
    case onenote
    case evernote
    case milanote
    case miro
    case excalidraw
    case whimsical
    case xmind
    case coggle
    case todoist
    case ticktick
    case googleCalendar
    case trello
    case canva
    case googleSlides
    case beautifulAi
    case prezi
    case pitch
    case unsplash
    case pexels
    case theNounProject
    case flaticon
    case coolors
    case googleFonts
    case removeBg
    case figma
    case loom
    case obsStudio
    case descript
    case audacity
    case davinciResolve
    case datawrapper
    case flourish
    case saveMyExams
    case physicsMathsTutor
    case revisionWorld
    case senecaLearning
    case bbcBitesize
    case crashcourse
    case khanAcademySat
    case collegeBoard
    case ibDocuments
    case quizizz
    case kahoot
    case wooclap
    case socratic
    case cheggStudy
    case courseHero
    case studocu
    case sparknotes
    case litcharts
    case shmoop
    case markedByTeachers
    case headspace
    case calm
    case insightTimer
    case finch
    case daylio
    case stretchly
    case fLux
    case waterReminder
    case nikeTraining
    case yogaWithAdriene
    case t7Cups
    case studentMinds
    case sleepytiMe
    case myfitnesspal

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all
        case ai
        case writing
        case research
        case math
        case science
        case coding
        case languages
        case focus
        case memory
        case presenting
        case revision
        case wellbeing
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .ai: "AI help"
            case .writing: "Writing"
            case .research: "Research"
            case .math: "Maths"
            case .science: "Science"
            case .coding: "Coding"
            case .languages: "Languages"
            case .focus: "Focus"
            case .memory: "Notes & memory"
            case .presenting: "Presenting"
            case .revision: "Revision"
            case .wellbeing: "Wellbeing"
            }
        }
    }

    /// Name, host, category, symbol and the one line explaining why you would
    /// open it. Kept in one table so a new tool is a single edit.
    ///
    /// No colour here on purpose — see the note on logos above.
    private var spec: (name: String, host: String, category: Category,
                       symbol: String, reason: String) {
        switch self {
        case .claude: ("Claude", "claude.ai", .ai, "sparkles", "Think a problem through out loud")
        case .chatgpt: ("ChatGPT", "chat.openai.com", .ai, "bubble.left.and.text.bubble.right", "Explains, drafts, and argues back")
        case .perplexityPro: ("Perplexity Pro", "perplexity.ai", .ai, "sparkle.magnifyingglass", "Answers that cite their sources")
        case .notebooklm: ("NotebookLM", "notebooklm.google.com", .ai, "book.and.wrench", "Asks questions of your own notes")
        case .gemini: ("Gemini", "gemini.google.com", .ai, "diamond", "Google's assistant, in your docs")
        case .consensus: ("Consensus", "consensus.app", .ai, "checkmark.message", "What the papers actually conclude")
        case .elicit: ("Elicit", "elicit.com", .ai, "tray.2", "Literature review, automated")
        case .scite: ("Scite", "scite.ai", .ai, "quote.bubble.fill", "Shows who disputes a citation")
        case .grammarly: ("Grammarly", "grammarly.com", .writing, "checkmark.bubble", "Grammar and clarity checks")
        case .hemingwayEditor: ("Hemingway Editor", "hemingwayapp.com", .writing, "scissors", "Cuts sentences down to size")
        case .prowritingaid: ("ProWritingAid", "prowritingaid.com", .writing, "text.magnifyingglass", "Style report on a long draft")
        case .languagetool: ("LanguageTool", "languagetool.org", .writing, "abc", "Grammar in 25+ languages")
        case .quillbot: ("Quillbot", "quillbot.com", .writing, "arrow.2.squarepath", "Rephrase a sentence you're stuck on")
        case .thesaurusCom: ("Thesaurus.com", "thesaurus.com", .writing, "book.closed", "The word on the tip of your tongue")
        case .merriamWebster: ("Merriam-Webster", "merriam-webster.com", .writing, "character.book.closed", "Definitions with real citations")
        case .oxfordLearnerS: ("Oxford Learner's", "oxfordlearnersdictionaries.com", .writing, "text.book.closed", "Definitions built for learners")
        case .purdueOwl: ("Purdue OWL", "owl.purdue.edu", .writing, "graduationcap", "The citation rules, explained")
        case .hemingwayMode: ("Hemingway Mode", "typewritermode.com", .writing, "keyboard", "No backspace. Just write")
        case .notion: ("Notion", "notion.so", .writing, "square.stack.3d.up", "Notes, docs and databases in one")
        case .obsidian: ("Obsidian", "obsidian.md", .writing, "link", "Notes that link to each other")
        case .googleDocs: ("Google Docs", "docs.google.com", .writing, "doc.text", "Write and share in the browser")
        case .overleaf: ("Overleaf", "overleaf.com", .writing, "function", "LaTeX without installing LaTeX")
        case .scrivener: ("Scrivener", "literatureandlatte.com", .writing, "doc.on.doc", "For work too long for one document")
        case .ulysses: ("Ulysses", "ulysses.app", .writing, "pencil.and.outline", "Distraction-free long-form writing")
        case .zotero: ("Zotero", "zotero.org", .writing, "books.vertical", "Collects sources and formats them")
        case .mendeley: ("Mendeley", "mendeley.com", .writing, "doc.badge.plus", "Reference manager with a PDF reader")
        case .endnote: ("EndNote", "endnote.com", .writing, "list.bullet.rectangle", "Reference manager universities use")
        case .citationMachine: ("Citation Machine", "citationmachine.net", .writing, "quote.opening", "One citation, formatted fast")
        case .zoterobib: ("ZoteroBib", "zbib.org", .writing, "quote.bubble", "A bibliography with no account")
        case .scribbr: ("Scribbr", "scribbr.com", .writing, "checkmark.seal", "Citation guides and a plagiarism check")
        case .hemingwayGrade: ("Hemingway Grade", "readabilityformulas.com", .writing, "gauge.medium", "How hard your writing is to read")
        case .wordcounter: ("WordCounter", "wordcounter.net", .writing, "number", "Words, characters, reading time")
        case .onelook: ("OneLook", "onelook.com", .writing, "magnifyingglass", "Find the word from its meaning")
        case .googleScholar: ("Google Scholar", "scholar.google.com", .research, "graduationcap.circle", "Scholarly articles and citations")
        case .jstor: ("JSTOR", "jstor.org", .research, "building.columns", "Journals and primary sources")
        case .pubmed: ("PubMed", "pubmed.ncbi.nlm.nih.gov", .research, "cross.case", "Biomedical and life-science papers")
        case .arxiv: ("arXiv", "arxiv.org", .research, "doc.plaintext", "Preprints in physics, maths, CS")
        case .semanticScholar: ("Semantic Scholar", "semanticscholar.org", .research, "brain", "Finds the papers that matter")
        case .connectedPapers: ("Connected Papers", "connectedpapers.com", .research, "point.3.connected.trianglepath.dotted", "A map of a field from one paper")
        case .researchgate: ("ResearchGate", "researchgate.net", .research, "person.2", "Papers straight from the authors")
        case .core: ("CORE", "core.ac.uk", .research, "square.grid.3x3", "Open-access papers, all of them")
        case .doaj: ("DOAJ", "doaj.org", .research, "lock.open", "Directory of open-access journals")
        case .sciHubAlternatives: ("Sci-Hub Alternatives", "openaccessbutton.org", .research, "key", "Legal routes to a paywalled paper")
        case .unpaywall: ("Unpaywall", "unpaywall.org", .research, "lock.open.rotation", "Finds the free version of a paper")
        case .internetArchive: ("Internet Archive", "archive.org", .research, "clock.arrow.circlepath", "Books, pages and media, preserved")
        case .projectGutenberg: ("Project Gutenberg", "gutenberg.org", .research, "book", "Sixty thousand free books")
        case .perplexity: ("Perplexity", "perplexity.ai", .research, "sparkle.magnifyingglass", "Answers that cite their sources")
        case .wikipedia: ("Wikipedia", "wikipedia.org", .research, "globe", "Start here, then follow the footnotes")
        case .britannica: ("Britannica", "britannica.com", .research, "building.columns.circle", "Encyclopaedia you can cite")
        case .ourWorldInData: ("Our World in Data", "ourworldindata.org", .research, "chart.xyaxis.line", "Charts you can actually cite")
        case .statista: ("Statista", "statista.com", .research, "chart.bar.doc.horizontal", "Statistics with sources attached")
        case .worldBankData: ("World Bank Data", "data.worldbank.org", .research, "globe.americas", "Country-level economic data")
        case .unData: ("UN Data", "data.un.org", .research, "globe.europe.africa", "Official international statistics")
        case .eurostat: ("Eurostat", "ec.europa.eu", .research, "flag", "European statistics")
        case .googleDatasetSearch: ("Google Dataset Search", "datasetsearch.research.google.com", .research, "tablecells", "Finds datasets across the web")
        case .libraryGenesisInfo: ("Library Genesis Info", "openlibrary.org", .research, "books.vertical.circle", "Open Library's lending catalogue")
        case .hathitrust: ("HathiTrust", "hathitrust.org", .research, "text.book.closed.fill", "Digitised academic library")
        case .jstorDaily: ("JSTOR Daily", "daily.jstor.org", .research, "newspaper", "Scholarship explained readably")
        case .nature: ("Nature", "nature.com", .research, "leaf", "The journal, and its news")
        case .science: ("Science", "science.org", .research, "atom", "AAAS research and commentary")
        case .ssrn: ("SSRN", "ssrn.com", .research, "doc.richtext", "Social-science preprints")
        case .philpapers: ("PhilPapers", "philpapers.org", .research, "bubble.left.and.bubble.right", "Philosophy index and archive")
        case .historicalAtlas: ("Historical Atlas", "worldhistory.org", .research, "map", "World history encyclopaedia")
        case .wolframAlpha: ("Wolfram Alpha", "wolframalpha.com", .math, "function", "Computational answers, step by step")
        case .symbolab: ("Symbolab", "symbolab.com", .math, "x.squareroot", "Solves and shows the working")
        case .desmos: ("Desmos", "desmos.com", .math, "chart.dots.scatter", "Graphing that makes it obvious")
        case .geogebra: ("GeoGebra", "geogebra.org", .math, "triangle", "Geometry, algebra and calculus")
        case .photomath: ("Photomath", "photomath.com", .math, "camera.viewfinder", "Point at the problem, see the steps")
        case .mathway: ("Mathway", "mathway.com", .math, "equal.square", "Step-by-step across every branch")
        case .khanAcademy: ("Khan Academy", "khanacademy.org", .math, "play.rectangle", "Free lessons and practice")
        case .brilliant: ("Brilliant", "brilliant.org", .math, "lightbulb", "Maths by solving, not watching")
        case .paulSNotes: ("Paul's Notes", "tutorial.math.lamar.edu", .math, "doc.text.below.ecg", "Calculus notes that actually explain")
        case .t3Blue1Brown: ("3Blue1Brown", "3blue1brown.com", .math, "eye", "The intuition behind the formula")
        case .integralCalculator: ("Integral Calculator", "integral-calculator.com", .math, "sum", "Integrals with the steps shown")
        case .derivativeCalculator: ("Derivative Calculator", "derivative-calculator.net", .math, "angle", "Derivatives with the steps shown")
        case .matrixCalculator: ("Matrix Calculator", "matrixcalc.org", .math, "square.grid.3x3.fill", "Linear algebra, worked through")
        case .statisticsKingdom: ("Statistics Kingdom", "statskingdom.com", .math, "chart.bar", "Runs the test and reads the result")
        case .desmosMatrix: ("Desmos Matrix", "desmos.com", .math, "squareshape.split.2x2", "Matrices you can see")
        case .sagemath: ("SageMath", "sagemath.org", .math, "terminal", "Open-source computer algebra")
        case .numbas: ("Numbas", "numbas.mathcentre.ac.uk", .math, "checklist", "Practice questions that mark themselves")
        case .projectEuler: ("Project Euler", "projecteuler.net", .math, "number.square", "Maths problems worth the struggle")
        case .oeis: ("OEIS", "oeis.org", .math, "list.number", "Identify any integer sequence")
        case .mathigon: ("Mathigon", "mathigon.org", .math, "puzzlepiece", "Textbook that talks back")
        case .phetSimulations: ("PhET Simulations", "phet.colorado.edu", .science, "atom", "Run the experiment in a browser")
        case .chemspider: ("ChemSpider", "chemspider.com", .science, "testtube.2", "Chemical structures and properties")
        case .pubchem: ("PubChem", "pubchem.ncbi.nlm.nih.gov", .science, "flask", "The chemistry database")
        case .periodicTable: ("Periodic Table", "ptable.com", .science, "tablecells.badge.ellipsis", "Interactive, and actually useful")
        case .biorender: ("BioRender", "biorender.com", .science, "waveform.path.ecg", "Diagrams that look publishable")
        case .proteinDataBank: ("Protein Data Bank", "rcsb.org", .science, "circles.hexagongrid", "3D structures of proteins")
        case .nasaEarthdata: ("NASA Earthdata", "earthdata.nasa.gov", .science, "globe.badge.chevron.backward", "Satellite and climate data")
        case .stellariumWeb: ("Stellarium Web", "stellarium-web.org", .science, "moon.stars", "The sky from anywhere, any date")
        case .physicsClassroom: ("Physics Classroom", "physicsclassroom.com", .science, "bolt", "Mechanics explained slowly")
        case .hyperphysics: ("HyperPhysics", "hyperphysics.gsu.edu", .science, "link.circle", "Physics as a concept map")
        case .anatomyAtlas: ("Anatomy Atlas", "innerbody.com", .science, "figure.stand", "Human anatomy, layer by layer")
        case .geneticsHomeRef: ("Genetics Home Ref", "medlineplus.gov", .science, "allergens", "Genetics for non-specialists")
        case .climateData: ("Climate Data", "climate.gov", .science, "thermometer.medium", "Climate records and explainers")
        case .usgs: ("USGS", "usgs.gov", .science, "mountain.2", "Geology, water and hazards")
        case .encyclopediaOfLife: ("Encyclopedia of Life", "eol.org", .science, "tortoise", "Every known species")
        case .foldit: ("Foldit", "fold.it", .science, "hand.raised", "Protein folding as a puzzle")
        case .labster: ("Labster", "labster.com", .science, "flask.fill", "Virtual lab work")
        case .concordConsortium: ("Concord Consortium", "learn.concord.org", .science, "atom", "Free science simulations")
        case .github: ("GitHub", "github.com", .coding, "chevron.left.forwardslash.chevron.right", "Code hosting and history")
        case .replit: ("Replit", "replit.com", .coding, "play.square", "Write and run code in the browser")
        case .stackOverflow: ("Stack Overflow", "stackoverflow.com", .coding, "questionmark.bubble", "Someone has hit this before")
        case .mdnWebDocs: ("MDN Web Docs", "developer.mozilla.org", .coding, "doc.append", "The web platform reference")
        case .w3Schools: ("W3Schools", "w3schools.com", .coding, "tag", "Quick syntax, quick examples")
        case .leetcode: ("LeetCode", "leetcode.com", .coding, "brain.head.profile", "Interview-style problem practice")
        case .hackerrank: ("HackerRank", "hackerrank.com", .coding, "terminal.fill", "Practice with automated marking")
        case .codecademy: ("Codecademy", "codecademy.com", .coding, "laptopcomputer", "Learn by typing, not watching")
        case .freecodecamp: ("freeCodeCamp", "freecodecamp.org", .coding, "flame", "Full curriculum, genuinely free")
        case .exercism: ("Exercism", "exercism.org", .coding, "dumbbell", "Small exercises, human feedback")
        case .regex101: ("Regex101", "regex101.com", .coding, "textformat.abc.dottedunderline", "Explains your regex back to you")
        case .jsonFormatter: ("JSON Formatter", "jsonformatter.org", .coding, "curlybraces", "Makes unreadable JSON readable")
        case .compilerExplorer: ("Compiler Explorer", "godbolt.org", .coding, "cpu", "See what your code compiles to")
        case .devdocs: ("DevDocs", "devdocs.io", .coding, "books.vertical.fill", "Every API doc, one search box")
        case .codepen: ("CodePen", "codepen.io", .coding, "square.on.square", "Front-end sketching")
        case .jupyter: ("Jupyter", "jupyter.org", .coding, "book.and.wrench", "Notebooks for data work")
        case .googleColab: ("Google Colab", "colab.research.google.com", .coding, "cloud", "Notebooks with a free GPU")
        case .kaggle: ("Kaggle", "kaggle.com", .coding, "chart.bar.xaxis", "Datasets and data-science practice")
        case .pythonDocs: ("Python Docs", "docs.python.org", .coding, "chevron.left.slash.chevron.right", "The language reference")
        case .swiftDocs: ("Swift Docs", "swift.org", .coding, "swift", "The Swift language guide")
        case .visualStudioCode: ("Visual Studio Code", "code.visualstudio.com", .coding, "square.and.pencil", "The editor most people use")
        case .gitDocs: ("Git Docs", "git-scm.com", .coding, "arrow.triangle.branch", "What that git command does")
        case .deepl: ("DeepL", "deepl.com", .languages, "character.bubble", "Translation that reads naturally")
        case .linguee: ("Linguee", "linguee.com", .languages, "text.quote", "Translations in real sentences")
        case .googleTranslate: ("Google Translate", "translate.google.com", .languages, "globe.badge.chevron.backward", "Fast, everywhere, every language")
        case .wordreference: ("WordReference", "wordreference.com", .languages, "character.book.closed.fill", "Dictionary plus forum arguments")
        case .duolingo: ("Duolingo", "duolingo.com", .languages, "bird", "Fifteen minutes a day")
        case .anki: ("Anki", "apps.ankiweb.net", .languages, "rectangle.stack", "Spaced repetition that works")
        case .memrise: ("Memrise", "memrise.com", .languages, "brain.filled.head.profile", "Vocabulary from real speakers")
        case .conjuguemos: ("Conjuguemos", "conjuguemos.com", .languages, "arrow.trianglehead.2.clockwise", "Verb conjugation drills")
        case .reversoContext: ("Reverso Context", "context.reverso.net", .languages, "text.alignleft", "How the phrase is actually used")
        case .forvo: ("Forvo", "forvo.com", .languages, "speaker.wave.2", "Hear a native say the word")
        case .tatoeba: ("Tatoeba", "tatoeba.org", .languages, "text.bubble", "Example sentences, many languages")
        case .lang8Hinative: ("Lang-8 / HiNative", "hinative.com", .languages, "person.wave.2", "Ask a native speaker")
        case .clozemaster: ("Clozemaster", "clozemaster.com", .languages, "square.dashed", "Vocabulary in context, gamified")
        case .readlang: ("Readlang", "readlang.com", .languages, "doc.text.magnifyingglass", "Read real pages with a click-dictionary")
        case .forest: ("Forest", "forestapp.cc", .focus, "tree", "Grow a tree by not touching your phone")
        case .pomofocus: ("Pomofocus", "pomofocus.io", .focus, "timer", "A clean pomodoro timer")
        case .togglTrack: ("Toggl Track", "toggl.com", .focus, "stopwatch", "Where the hours actually went")
        case .coldTurkey: ("Cold Turkey", "getcoldturkey.com", .focus, "hand.raised.slash", "Blocks sites properly")
        case .freedom: ("Freedom", "freedom.to", .focus, "lock.shield", "Blocks across all your devices")
        case .noisli: ("Noisli", "noisli.com", .focus, "waveform", "Background noise that helps")
        case .brainFm: ("Brain.fm", "brain.fm", .focus, "headphones", "Music built for concentration")
        case .rainyMood: ("Rainy Mood", "rainymood.com", .focus, "cloud.rain", "Rain, and nothing else")
        case .lofiGirl: ("Lofi Girl", "lofigirl.com", .focus, "music.note", "The one everybody uses")
        case .focusmate: ("Focusmate", "focusmate.com", .focus, "person.2.wave.2", "A stranger works alongside you")
        case .studyTogether: ("Study Together", "studytogether.com", .focus, "rectangle.3.group", "Virtual library rooms")
        case .habitica: ("Habitica", "habitica.com", .focus, "gamecontroller", "Habits as a role-playing game")
        case .streaks: ("Streaks", "streaksapp.com", .focus, "flame.fill", "Keep the chain unbroken")
        case .sleepCycle: ("Sleep Cycle", "sleepcycle.com", .focus, "bed.double", "Because sleep is study time")
        case .quizlet: ("Quizlet", "quizlet.com", .memory, "rectangle.on.rectangle", "Flashcards, and everyone else's")
        case .ankiWeb: ("Anki Web", "ankiweb.net", .memory, "rectangle.stack.fill", "Your Anki deck in a browser")
        case .remnote: ("RemNote", "remnote.com", .memory, "note.text", "Notes that become flashcards")
        case .brainscape: ("Brainscape", "brainscape.com", .memory, "square.stack", "Confidence-based repetition")
        case .cram: ("Cram", "cram.com", .memory, "rectangle.split.3x1", "Flashcards without an account")
        case .knowt: ("Knowt", "knowt.com", .memory, "doc.text.fill", "Turns your notes into a quiz")
        case .goodnotes: ("GoodNotes", "goodnotes.com", .memory, "hand.draw", "Handwriting that stays searchable")
        case .notability: ("Notability", "notability.com", .memory, "pencil.tip", "Notes with the lecture recorded")
        case .onenote: ("OneNote", "onenote.com", .memory, "note", "Free, and syncs everywhere")
        case .evernote: ("Evernote", "evernote.com", .memory, "square.and.pencil.circle", "The original notes app")
        case .milanote: ("Milanote", "milanote.com", .memory, "square.grid.2x2", "Notes on a board, not a list")
        case .miro: ("Miro", "miro.com", .memory, "rectangle.dashed", "A whiteboard big enough")
        case .excalidraw: ("Excalidraw", "excalidraw.com", .memory, "scribble", "Diagrams that look hand-drawn")
        case .whimsical: ("Whimsical", "whimsical.com", .memory, "flowchart", "Flowcharts and mind maps")
        case .xmind: ("XMind", "xmind.app", .memory, "point.topleft.down.to.point.bottomright.curvepath", "Mind maps that stay tidy")
        case .coggle: ("Coggle", "coggle.it", .memory, "circle.hexagongrid", "Shared mind maps")
        case .todoist: ("Todoist", "todoist.com", .memory, "checklist.checked", "The list that actually gets used")
        case .ticktick: ("TickTick", "ticktick.com", .memory, "checkmark.circle", "Tasks with a pomodoro built in")
        case .googleCalendar: ("Google Calendar", "calendar.google.com", .memory, "calendar", "Where your real week lives")
        case .trello: ("Trello", "trello.com", .memory, "square.grid.3x1.below.line.grid.1x2", "Boards for a group project")
        case .canva: ("Canva", "canva.com", .presenting, "paintpalette", "Design without being a designer")
        case .googleSlides: ("Google Slides", "slides.google.com", .presenting, "rectangle.on.rectangle.angled", "Slides you can share instantly")
        case .beautifulAi: ("Beautiful.ai", "beautiful.ai", .presenting, "wand.and.stars", "Slides that lay themselves out")
        case .prezi: ("Prezi", "prezi.com", .presenting, "arrow.up.left.and.down.right.magnifyingglass", "When a straight line won't do")
        case .pitch: ("Pitch", "pitch.com", .presenting, "play.rectangle.on.rectangle", "Decks built with other people")
        case .unsplash: ("Unsplash", "unsplash.com", .presenting, "photo", "Free photographs worth using")
        case .pexels: ("Pexels", "pexels.com", .presenting, "photo.stack", "Free photos and video")
        case .theNounProject: ("The Noun Project", "thenounproject.com", .presenting, "square.on.circle", "An icon for anything")
        case .flaticon: ("Flaticon", "flaticon.com", .presenting, "star.square", "Icons, many formats")
        case .coolors: ("Coolors", "coolors.co", .presenting, "swatchpalette", "A palette in three seconds")
        case .googleFonts: ("Google Fonts", "fonts.google.com", .presenting, "textformat", "Free type that loads fast")
        case .removeBg: ("Remove.bg", "remove.bg", .presenting, "person.crop.rectangle", "Cuts out the background")
        case .figma: ("Figma", "figma.com", .presenting, "pencil.and.ruler", "Design, together, in a browser")
        case .loom: ("Loom", "loom.com", .presenting, "record.circle", "Record the walkthrough instead")
        case .obsStudio: ("OBS Studio", "obsproject.com", .presenting, "video", "Record or stream your screen")
        case .descript: ("Descript", "descript.com", .presenting, "waveform.badge.mic", "Edit audio by editing text")
        case .audacity: ("Audacity", "audacityteam.org", .presenting, "waveform.circle", "Free audio editing")
        case .davinciResolve: ("DaVinci Resolve", "blackmagicdesign.com", .presenting, "film", "Professional video, free tier")
        case .datawrapper: ("Datawrapper", "datawrapper.de", .presenting, "chart.pie", "Charts that explain themselves")
        case .flourish: ("Flourish", "flourish.studio", .presenting, "chart.line.uptrend.xyaxis.circle", "Animated data storytelling")
        case .saveMyExams: ("Save My Exams", "savemyexams.com", .revision, "doc.badge.gearshape", "Revision notes by exam board")
        case .physicsMathsTutor: ("Physics & Maths Tutor", "physicsandmathstutor.com", .revision, "tray.full", "Past papers, sorted by topic")
        case .revisionWorld: ("Revision World", "revisionworld.com", .revision, "book.pages", "Notes across GCSE and A-level")
        case .senecaLearning: ("Seneca Learning", "senecalearning.com", .revision, "brain.head.profile.fill", "Revision that adapts to you")
        case .bbcBitesize: ("BBC Bitesize", "bbc.co.uk", .revision, "tv", "Short, clear, and free")
        case .crashcourse: ("CrashCourse", "thecrashcourse.com", .revision, "play.tv", "A subject in ten-minute pieces")
        case .khanAcademySat: ("Khan Academy SAT", "khanacademy.org", .revision, "pencil.circle", "Official SAT practice")
        case .collegeBoard: ("College Board", "collegeboard.org", .revision, "building.columns.fill", "AP and SAT, from the source")
        case .ibDocuments: ("IB Documents", "ibo.org", .revision, "doc.zipper", "The official IB subject guides")
        case .quizizz: ("Quizizz", "quizizz.com", .revision, "gamecontroller.fill", "Revision as a class game")
        case .kahoot: ("Kahoot", "kahoot.com", .revision, "flag.checkered", "The one everyone shouts at")
        case .wooclap: ("Wooclap", "wooclap.com", .revision, "hand.thumbsup", "Live questions in a lecture")
        case .socratic: ("Socratic", "socratic.org", .revision, "camera.metering.center.weighted", "Photograph the question")
        case .cheggStudy: ("Chegg Study", "chegg.com", .revision, "book.circle", "Worked textbook solutions")
        case .courseHero: ("Course Hero", "coursehero.com", .revision, "doc.on.clipboard", "Course notes from other students")
        case .studocu: ("Studocu", "studocu.com", .revision, "doc.text.image", "Shared summaries and past papers")
        case .sparknotes: ("SparkNotes", "sparknotes.com", .revision, "book.closed.fill", "The novel, and what it means")
        case .litcharts: ("LitCharts", "litcharts.com", .revision, "text.book.closed", "Literature analysis, colour-coded")
        case .shmoop: ("Shmoop", "shmoop.com", .revision, "face.smiling", "Literature with a sense of humour")
        case .markedByTeachers: ("Marked by Teachers", "markedbyteachers.com", .revision, "checkmark.rectangle.stack", "Real essays with real marks")
        case .headspace: ("Headspace", "headspace.com", .wellbeing, "figure.mind.and.body", "Ten minutes before you start")
        case .calm: ("Calm", "calm.com", .wellbeing, "moon.zzz", "For the night before")
        case .insightTimer: ("Insight Timer", "insighttimer.com", .wellbeing, "timer.circle", "Free guided meditation")
        case .finch: ("Finch", "finchcare.com", .wellbeing, "bird.fill", "Self-care that doesn't feel like it")
        case .daylio: ("Daylio", "daylio.net", .wellbeing, "face.dashed", "Mood in two taps a day")
        case .stretchly: ("Stretchly", "hovancik.net", .wellbeing, "figure.flexibility", "Reminds you to look away")
        case .fLux: ("f.lux", "justgetflux.com", .wellbeing, "sun.horizon", "Screen warmth after dark")
        case .waterReminder: ("Water Reminder", "waterllama.app", .wellbeing, "drop", "Drink something that isn't coffee")
        case .nikeTraining: ("Nike Training", "nike.com", .wellbeing, "figure.run", "Twenty minutes, no equipment")
        case .yogaWithAdriene: ("Yoga with Adriene", "yogawithadriene.com", .wellbeing, "figure.yoga", "Free, and genuinely kind")
        case .t7Cups: ("7 Cups", "7cups.com", .wellbeing, "heart.text.square", "Someone to talk to, free")
        case .studentMinds: ("Student Minds", "studentminds.org.uk", .wellbeing, "hand.raised.fill", "Student mental health support")
        case .sleepytiMe: ("Sleepyti.me", "sleepyti.me", .wellbeing, "alarm", "When to go to bed, working back")
        case .myfitnesspal: ("MyFitnessPal", "myfitnesspal.com", .wellbeing, "fork.knife", "Eating like a person, not a student")
        }
    }

    var name: String { spec.name }
    var category: Category { spec.category }
    var reason: String { spec.reason }
    /// Shape-only fallback used when no real logo is bundled. Rendered in a
    /// neutral ink, never a brand colour this app guessed at.
    var symbolName: String { spec.symbol }
    /// Asset name a bundled brand logo would use.
    var logoAssetName: String { "logo-\(rawValue)" }

    /// Shown to a student when asked where a tap will take them.
    var host: String { spec.host }

    /// Every string here is a literal this file controls, so it cannot fail —
    /// and a typo is caught by `ToolCatalogTests`, not by a student tapping a
    /// dead tile.
    var url: URL { URL(string: "https://\(spec.host)")! }

    /// Matches a search across name, reason and category.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || reason.lowercased().contains(q)
            || category.title.lowercased().contains(q)
    }

    /// Maps a plan step to the tools worth opening for it.
    ///
    /// Keyword matching on purpose: instant, free, works offline, and wrong in
    /// ways a student can see and ignore. A model call here would cost money
    /// per step to produce a guess of the same quality.
    static func suggested(for step: Subtask) -> [StudyTool] {
        let text = (step.title + " " + (step.guidance ?? "")).lowercased()
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        var out: [StudyTool] = []
        if any(["research", "source", "read", "find", "evidence", "cite"]) {
            out += [.jstor, .googleScholar]
        }
        if any(["outline", "plan", "structure", "draft", "write", "brainstorm", "argument", "essay"]) {
            out += [.notion, .grammarly]
        }
        if any(["review", "edit", "proofread", "revise", "polish"]) {
            out += [.grammarly, .hemingwayEditor]
        }
        if any(["solve", "equation", "calculate", "problem set", "derive", "integral"]) {
            out += [.wolframAlpha, .symbolab]
        }
        if any(["code", "program", "implement", "debug"]) {
            out += [.github, .replit]
        }
        if any(["translate", "vocabulary", "conjugat"]) {
            out += [.deepl, .linguee]
        }
        if any(["memoris", "memoriz", "revise", "flashcard", "recall", "learn"]) {
            out += [.anki, .quizlet]
        }
        // Three is the most a step row can show without wrapping.
        var seen = Set<StudyTool>()
        return out.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }
}
