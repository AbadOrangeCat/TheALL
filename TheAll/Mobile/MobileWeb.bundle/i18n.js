const strings = {
  pairTitle: ['Your workspace.\nAnywhere.', '你的工作空间，\n随时在手边。'],
  pairDescription: ['Connect to TheAll on your Mac to continue your conversations and keep work moving.', '连接 Mac 上的 TheAll，在手机上继续对话，让电脑继续工作。'],
  pairToken: ['Pairing code', '配对码'], deviceName: ['This device', '设备名称'], connect: ['Connect to Mac', '连接 Mac'],
  pairHelp: ["Scan the QR code in TheAll → Mobile access on your Mac to connect automatically. If a code expires, scan a new one.", "扫描 Mac 上 TheAll「手机连接」中的二维码即可自动连接。二维码过期时，请重新生成并扫码。"],
  install: ['Add to home screen', '添加到主屏幕'], workspaces: ['Workspaces', '工作空间'], disconnect: ['Disconnect this device', '断开此设备'],
  chooseChat: ['Choose a conversation', '选择一个对话'], welcomeTitle: ['Keep your ideas moving.', '让灵感继续。'],
  welcomeDetail: ['Open a workspace or start a conversation. Everything runs on your Mac.', '打开工作空间，或发起新对话。所有任务都在你的 Mac 上运行。'],
  newChat: ['New conversation', '新建对话'], older: ['Load earlier messages', '查看更早的消息'], working: ['Working on your Mac…', '正在 Mac 上处理…'],
  message: ['Message', '消息'], messagePlaceholder: ['Continue the conversation…', '继续对话…'], model: ['Model', '模型'], send: ['Send ↑', '发送 ↑'], stop: ['Stop ■', '停止 ■'],
  modelNotice: ['The selected model applies to your next message. Chat history is kept.', '所选模型将在下一条消息生效，对话历史会保留。'],
  retry: ['Retry same request', '重试同一请求'], setupNotice: ['Configure this AI connection in TheAll on your Mac before sending messages.', '请先在 Mac 的 TheAll 中配置此 AI 的连接，再发送消息。'],
  workspace: ['Workspace', '工作空间'], provider: ['AI provider', 'AI 类型'], directory: ['Folder on your Mac', 'Mac 上的工作文件夹'],
  newHelp: ['Uses the saved API connection on your Mac. Enter an existing folder on that Mac.', '使用 Mac 上已保存的 API 连接。请填写该 Mac 上已存在的文件夹路径。'],
  create: ['Create conversation', '创建对话'], installIOS: ['Open this address in Safari, tap Share, then Add to Home Screen. If the installed app asks you to pair again, generate a new code on your Mac.', '在 Safari 中打开此地址，点击「分享」→「添加到主屏幕」。如果安装后需要重新配对，在 Mac 上生成新的配对码即可。'],
  installAndroid: ['Open this address in Chrome, then choose Install app or Add to home screen from the menu.', '在 Chrome 中打开此地址，在菜单中选择「安装应用」或「添加到主屏幕」。'],
  installNetwork: ["Keep your Mac awake and TheAll running. Use your Mac’s local address on the same Wi-Fi, or your relay address when away. No VPN app is needed.", "请保持 Mac 唤醒且 TheAll 正在运行；同一 Wi-Fi 下使用 Mac 的局域网地址，外出时使用中继地址，无需额外的 VPN 应用。"],
  installNow: ['Install TheAll', '安装 TheAll'], connected: ['Connected', '已连接'], offline: ['Offline', '未连接'],
  networkError: ['Cannot reach your Mac. Keep TheAll running, wake your Mac, and check the local network or internet relay.', '无法连接 Mac。请保持 TheAll 运行、唤醒 Mac，并检查局域网或外网中继。'],
  unknownResult: ['Connection interrupted. This action may already have reached your Mac. Retry the same request to check without submitting it twice.', '连接中断，此操作可能已到达 Mac。可重试同一请求确认结果，不会重复提交。'],
  authExpired: ['This device is not paired or its access was revoked. Generate a new pairing code on your Mac.', '此设备尚未配对，或访问权限已被撤销。请在 Mac 上生成新的配对码。'],
  secureRequired: ["Scan the address shown on your Mac. Connections require HTTPS or a private Wi-Fi address.", "请扫描 Mac 上显示的地址。仅支持 HTTPS 或局域网内的地址。"],
  newWorkspace: ['＋ New workspace', '＋ 新工作空间'], emptyWorkspace: ['No conversations yet', '暂无对话'], emptyList: ['No workspaces yet. Start a new conversation.', '暂无工作空间，可以创建新对话。'],
  you: ['You', '你'], thinking: ['Thinking', '思考过程'], updates: ['updates', '条进展'], defaultModel: ['Default model', '默认模型'],
  submitAnswer: ['Send answer', '提交回答'], otherAnswer: ['Or type an answer…', '也可以输入其他回答…'], requiredAnswer: ['Please answer each question.', '请回答所有问题。'],
  setup: ['Setup on Mac', '需在 Mac 配置'], running: ['Running', '运行中'], needsInput: ['Awaiting your answer', '等待你的回答'], idle: ['Ready', '就绪'],
  loading: ['Loading…', '加载中…'], noMessages: ['Start the conversation. Your Mac is ready.', '发送第一条消息，让 Mac 开始工作。'],
  absoluteDirectory: ['Enter an absolute folder path on your Mac, starting with /.', '请输入 Mac 上以 / 开头的完整文件夹路径。'],
  sending: ['Sending…', '发送中…'], close: ['Close', '关闭'], openWorkspaces: ['Open workspaces', '打开工作空间'], jumpBottom: ['Jump to latest message', '跳到最新消息'],
  discardRetry: ['I checked the conversation; stop retrying', '已检查对话，取消重试'],
  logoutFailed: ['Could not disconnect. Retry when your Mac is reachable, or revoke this device from TheAll on your Mac.', '暂时无法断开。请在 Mac 可连接时重试，或在 Mac 的 TheAll 中撤销此设备。']
};
Object.assign(strings, {
  language: ['Language', '语言'], history: ['Conversation history', '对话记录'],
  readOnly: ['Read-only access', '只读访问'], writable: ['Can view and control', '可查看与操作'],
  allWorkspaces: ['All workspaces', '所有工作空间'], scopedWorkspace: ['Authorized workspace', '授权工作空间'],
  live: ['Live', '实时连接'], polling: ['Connected · syncing', '已连接 · 同步中'],
  mobile: ['Mobile', '手机端'], deviceMobile: ['Mobile device', '移动设备'],
  emptyReadOnly: ['No conversations to view yet.', '暂无可查看的对话。'],
  readOnlyWelcome: ['Choose a conversation to view its history and live updates.', '选择对话，查看历史记录与实时更新。'],
  readOnlyMessages: ['No messages yet.', '暂无消息。']
});
const french = {
  pairTitle: 'Votre espace de travail.\nPartout.',
  pairDescription: 'Connectez-vous à TheAll sur votre Mac pour poursuivre vos conversations et votre travail.',
  pairToken: 'Code d’association', deviceName: 'Cet appareil', connect: 'Connecter au Mac',
  pairHelp: "Scannez le code QR dans TheAll → Accès mobile sur votre Mac pour vous connecter automatiquement. Si le code expire, scannez-en un nouveau.",
  install: 'Ajouter à l’écran d’accueil', workspaces: 'Espaces de travail', disconnect: 'Déconnecter cet appareil',
  chooseChat: 'Choisir une conversation', welcomeTitle: 'Donnez suite à vos idées.',
  welcomeDetail: 'Ouvrez un espace de travail ou démarrez une conversation. Tout s’exécute sur votre Mac.',
  newChat: 'Nouvelle conversation', older: 'Afficher les messages précédents', working: 'Traitement sur votre Mac…',
  message: 'Message', messagePlaceholder: 'Poursuivre la conversation…', model: 'Modèle', send: 'Envoyer ↑', stop: 'Arrêter ■',
  modelNotice: 'Le modèle sélectionné s’appliquera au prochain message. L’historique est conservé.',
  retry: 'Réessayer la même requête', setupNotice: 'Configurez cette connexion IA dans TheAll sur votre Mac avant d’envoyer des messages.',
  workspace: 'Espace de travail', provider: 'Fournisseur IA', directory: 'Dossier sur votre Mac',
  newHelp: 'Utilise la connexion API enregistrée sur votre Mac. Saisissez le chemin d’un dossier existant sur ce Mac.',
  create: 'Créer la conversation',
  installIOS: 'Ouvrez cette adresse dans Safari, touchez Partager, puis Sur l’écran d’accueil. Si l’application installée demande une nouvelle association, générez un nouveau code sur votre Mac.',
  installAndroid: 'Ouvrez cette adresse dans Chrome, puis choisissez Installer l’application ou Ajouter à l’écran d’accueil dans le menu.',
  installNetwork: "Gardez votre Mac éveillé et TheAll ouvert. Utilisez son adresse locale sur le même Wi-Fi ou votre relais à distance. Aucune application VPN n’est nécessaire.",
  installNow: 'Installer TheAll', connected: 'Connecté', offline: 'Hors ligne',
  networkError: 'Impossible de joindre votre Mac. Gardez TheAll ouvert, réveillez votre Mac et vérifiez le réseau local ou le relais internet.',
  unknownResult: 'Connexion interrompue. Cette action a peut-être déjà atteint votre Mac. Réessayez la même requête pour vérifier sans la soumettre deux fois.',
  authExpired: 'Cet appareil n’est pas associé ou son accès a été révoqué. Générez un nouveau code d’association sur votre Mac.',
  secureRequired: "Scannez l’adresse affichée sur votre Mac. La connexion nécessite HTTPS ou une adresse de réseau privé.",
  newWorkspace: '＋ Nouvel espace de travail', emptyWorkspace: 'Aucune conversation', emptyList: 'Aucun espace de travail. Démarrez une conversation.',
  you: 'Vous', thinking: 'Réflexion', updates: 'étapes', defaultModel: 'Modèle par défaut',
  submitAnswer: 'Envoyer la réponse', otherAnswer: 'Ou saisissez une réponse…', requiredAnswer: 'Répondez à chaque question.',
  setup: 'À configurer sur le Mac', running: 'En cours', needsInput: 'En attente de votre réponse', idle: 'Prêt',
  loading: 'Chargement…', noMessages: 'Démarrez la conversation. Votre Mac est prêt.',
  absoluteDirectory: 'Saisissez un chemin absolu de dossier sur votre Mac, commençant par /.',
  sending: 'Envoi…', close: 'Fermer', openWorkspaces: 'Ouvrir les espaces de travail', jumpBottom: 'Aller au dernier message',
  discardRetry: 'J’ai vérifié la conversation ; ne plus réessayer',
  logoutFailed: 'Déconnexion impossible. Réessayez lorsque votre Mac est accessible ou révoquez cet appareil dans TheAll sur votre Mac.',
  language: 'Langue', history: 'Historique de la conversation', readOnly: 'Accès en lecture seule', writable: 'Consultation et contrôle',
  allWorkspaces: 'Tous les espaces de travail', scopedWorkspace: 'Espace de travail autorisé', live: 'En direct', polling: 'Connecté · synchronisation',
  mobile: 'Mobile', deviceMobile: 'Appareil mobile', emptyReadOnly: 'Aucune conversation à consulter.',
  readOnlyWelcome: 'Choisissez une conversation pour consulter son historique et ses mises à jour en direct.', readOnlyMessages: 'Aucun message.'
};
const japanese = {
  pairTitle: 'ワークスペースを、\nどこからでも。',
  pairDescription: 'Mac の TheAll に接続して、会話と作業を続けましょう。',
  pairToken: 'ペアリングコード', deviceName: 'このデバイス', connect: 'Mac に接続',
  pairHelp: "Mac の TheAll の「モバイルアクセス」で QR コードをスキャンすると自動接続します。期限が切れた場合は新しいコードをスキャンしてください。",
  install: 'ホーム画面に追加', workspaces: 'ワークスペース', disconnect: 'このデバイスを切断',
  chooseChat: '会話を選択', welcomeTitle: 'アイデアを、さらに先へ。',
  welcomeDetail: 'ワークスペースを開くか、新しい会話を始めましょう。すべての処理は Mac 上で実行されます。',
  newChat: '新しい会話', older: '以前のメッセージを表示', working: 'Mac で処理中…',
  message: 'メッセージ', messagePlaceholder: '会話を続ける…', model: 'モデル', send: '送信 ↑', stop: '停止 ■',
  modelNotice: '選択したモデルは次のメッセージから適用されます。会話の履歴は保持されます。',
  retry: '同じリクエストを再試行', setupNotice: 'メッセージを送信する前に、Mac の TheAll でこの AI 接続を設定してください。',
  workspace: 'ワークスペース', provider: 'AI プロバイダー', directory: 'Mac 上のフォルダ',
  newHelp: 'Mac に保存された API 接続を使用します。その Mac に存在するフォルダのパスを入力してください。',
  create: '会話を作成',
  installIOS: 'Safari でこのアドレスを開き、「共有」から「ホーム画面に追加」を選択します。追加後に再度ペアリングが必要な場合は、Mac で新しいコードを生成してください。',
  installAndroid: 'Chrome でこのアドレスを開き、メニューから「アプリをインストール」または「ホーム画面に追加」を選択してください。',
  installNetwork: "Mac をスリープさせず、TheAll を起動しておいてください。同じ Wi-Fi では Mac のローカルアドレスを、外出先では中継サーバーのアドレスを使います。VPN アプリは不要です。",
  installNow: 'TheAll をインストール', connected: '接続済み', offline: 'オフライン',
  networkError: 'Mac に接続できません。TheAll を起動し、Mac のスリープを解除して、ローカルネットワークまたはインターネット中継を確認してください。',
  unknownResult: '接続が切れました。この操作はすでに Mac に届いている可能性があります。同じリクエストを再試行すると、重複送信せずに結果を確認できます。',
  authExpired: 'このデバイスはペアリングされていないか、アクセスが取り消されました。Mac で新しいペアリングコードを生成してください。',
  secureRequired: "Mac に表示されたアドレスをスキャンしてください。HTTPS またはプライベートネットワークのアドレスが必要です。",
  newWorkspace: '＋ 新しいワークスペース', emptyWorkspace: '会話はまだありません', emptyList: 'ワークスペースがありません。新しい会話を始めてください。',
  you: 'あなた', thinking: '思考過程', updates: '件の進捗', defaultModel: 'デフォルトのモデル',
  submitAnswer: '回答を送信', otherAnswer: '別の回答を入力…', requiredAnswer: 'すべての質問に回答してください。',
  setup: 'Mac で設定が必要', running: '実行中', needsInput: '回答を待っています', idle: '準備完了',
  loading: '読み込み中…', noMessages: '会話を始めましょう。Mac の準備ができています。',
  absoluteDirectory: 'Mac 上のフォルダの絶対パスを / から入力してください。',
  sending: '送信中…', close: '閉じる', openWorkspaces: 'ワークスペースを開く', jumpBottom: '最新のメッセージへ',
  discardRetry: '会話を確認したので再試行を中止',
  logoutFailed: '切断できませんでした。Mac に接続できる状態で再試行するか、Mac の TheAll からこのデバイスのアクセスを取り消してください。',
  language: '言語', history: '会話の履歴', readOnly: '閲覧のみ', writable: '閲覧と操作が可能',
  allWorkspaces: 'すべてのワークスペース', scopedWorkspace: '許可されたワークスペース', live: 'リアルタイム接続', polling: '接続済み · 同期中',
  mobile: 'モバイル', deviceMobile: 'モバイルデバイス', emptyReadOnly: '閲覧できる会話はまだありません。',
  readOnlyWelcome: '会話を選択して、履歴やリアルタイムの更新を確認してください。', readOnlyMessages: 'メッセージはまだありません。'
};
const korean = {
  pairTitle: '어디서나 함께하는\n작업 공간.',
  pairDescription: 'Mac의 TheAll에 연결하여 대화를 이어 가고 작업을 계속하세요.',
  pairToken: '페어링 코드', deviceName: '이 기기', connect: 'Mac에 연결',
  pairHelp: "Mac의 TheAll → 모바일 접속에서 QR 코드를 스캔하면 자동 연결됩니다. 코드가 만료되면 새 코드를 스캔하세요.",
  install: '홈 화면에 추가', workspaces: '작업 공간', disconnect: '이 기기 연결 해제',
  chooseChat: '대화 선택', welcomeTitle: '아이디어를 계속 이어 가세요.',
  welcomeDetail: '작업 공간을 열거나 새 대화를 시작하세요. 모든 작업은 Mac에서 실행됩니다.',
  newChat: '새 대화', older: '이전 메시지 보기', working: 'Mac에서 처리 중…',
  message: '메시지', messagePlaceholder: '대화를 이어 가세요…', model: '모델', send: '보내기 ↑', stop: '중지 ■',
  modelNotice: '선택한 모델은 다음 메시지부터 적용됩니다. 대화 기록은 유지됩니다.',
  retry: '동일한 요청 다시 시도', setupNotice: '메시지를 보내기 전에 Mac의 TheAll에서 이 AI 연결을 설정하세요.',
  workspace: '작업 공간', provider: 'AI 제공업체', directory: 'Mac의 폴더',
  newHelp: 'Mac에 저장된 API 연결을 사용합니다. 해당 Mac에 존재하는 폴더 경로를 입력하세요.',
  create: '대화 만들기',
  installIOS: 'Safari에서 이 주소를 열고 공유 → 홈 화면에 추가를 선택하세요. 설치한 앱에서 다시 페어링을 요청하면 Mac에서 새 코드를 생성하세요.',
  installAndroid: 'Chrome에서 이 주소를 열고 메뉴에서 앱 설치 또는 홈 화면에 추가를 선택하세요.',
  installNetwork: "Mac을 깨운 상태로 TheAll을 실행하세요. 같은 Wi-Fi에서는 Mac의 로컬 주소를, 외부에서는 중계 주소를 사용하세요. VPN 앱은 필요하지 않습니다.",
  installNow: 'TheAll 설치', connected: '연결됨', offline: '오프라인',
  networkError: 'Mac에 연결할 수 없습니다. TheAll을 실행하고 Mac의 잠자기를 해제한 뒤 로컬 네트워크 또는 인터넷 중계를 확인하세요.',
  unknownResult: '연결이 끊어졌습니다. 이 작업이 이미 Mac에 전달되었을 수 있습니다. 동일한 요청을 다시 시도하면 중복 제출 없이 결과를 확인할 수 있습니다.',
  authExpired: '이 기기가 페어링되지 않았거나 접근 권한이 해제되었습니다. Mac에서 새 페어링 코드를 생성하세요.',
  secureRequired: "Mac에 표시된 주소를 스캔하세요. HTTPS 또는 사설 네트워크 주소가 필요합니다.",
  newWorkspace: '＋ 새 작업 공간', emptyWorkspace: '아직 대화가 없습니다', emptyList: '작업 공간이 없습니다. 새 대화를 시작하세요.',
  you: '나', thinking: '생각 과정', updates: '개의 진행 상황', defaultModel: '기본 모델',
  submitAnswer: '답변 보내기', otherAnswer: '또는 답변 입력…', requiredAnswer: '모든 질문에 답변해 주세요.',
  setup: 'Mac에서 설정 필요', running: '실행 중', needsInput: '답변 대기 중', idle: '준비됨',
  loading: '불러오는 중…', noMessages: '대화를 시작하세요. Mac이 준비되었습니다.',
  absoluteDirectory: '/로 시작하는 Mac 폴더의 절대 경로를 입력하세요.',
  sending: '보내는 중…', close: '닫기', openWorkspaces: '작업 공간 열기', jumpBottom: '최신 메시지로 이동',
  discardRetry: '대화를 확인했으므로 재시도 중단',
  logoutFailed: '연결을 해제하지 못했습니다. Mac에 연결할 수 있을 때 다시 시도하거나 Mac의 TheAll에서 이 기기의 권한을 해제하세요.',
  language: '언어', history: '대화 기록', readOnly: '읽기 전용', writable: '보기 및 조작 가능',
  allWorkspaces: '모든 작업 공간', scopedWorkspace: '허용된 작업 공간', live: '실시간 연결', polling: '연결됨 · 동기화 중',
  mobile: '모바일', deviceMobile: '모바일 기기', emptyReadOnly: '아직 볼 수 있는 대화가 없습니다.',
  readOnlyWelcome: '대화를 선택하여 기록과 실시간 업데이트를 확인하세요.', readOnlyMessages: '아직 메시지가 없습니다.'
};
export const supportedLanguages = { en: 'English', 'zh-Hans': '简体中文', fr: 'Français', ja: '日本語', ko: '한국어' };
export const catalog = Object.fromEntries(Object.keys(supportedLanguages).map((code, index) => [code,
  index < 2 ? Object.fromEntries(Object.entries(strings).map(([key, values]) => [key, values[index]]))
    : ({ fr: french, ja: japanese, ko: korean })[code]
]));
const photoStrings = {
  photosAdd: ['Add photos', '添加照片', 'Ajouter des photos', '写真を追加', '사진 추가'],
  photosRemove: ['Remove photo', '移除照片', 'Retirer la photo', '写真を削除', '사진 제거'],
  photosPreview: ['View photo', '查看照片', 'Voir la photo', '写真を見る', '사진 보기'],
  photosPreparing: ['Preparing photos…', '正在准备照片…', 'Préparation des photos…', '写真を準備中…', '사진 준비 중…'],
  photosTooMany: ['Attach up to 4 photos per message.', '每条消息最多添加 4 张照片。', 'Joignez jusqu’à 4 photos par message.', '1 件のメッセージに添付できる写真は 4 枚までです。', '메시지당 사진을 최대 4장 첨부할 수 있습니다.'],
  photosTooLarge: ['Choose photos under 20 MB and 100 megapixels each.', '请选择每张小于 20 MB、1 亿像素以内的照片。', 'Choisissez des photos de moins de 20 Mo et 100 mégapixels chacune.', '各写真は 20 MB 未満、1 億画素以内で選んでください。', '각 사진은 20 MB 미만, 1억 화소 이내로 선택하세요.'],
  photosInvalid: ['This photo cannot be read. For HEIC photos, export as JPEG or PNG and try again.', '无法读取这张照片。HEIC 照片可先导出为 JPEG 或 PNG 再试。', 'Cette photo est illisible. Pour une photo HEIC, exportez-la en JPEG ou PNG, puis réessayez.', 'この写真を読み込めません。HEIC の写真は JPEG または PNG に書き出して再試行してください。', '이 사진을 읽을 수 없습니다. HEIC 사진은 JPEG 또는 PNG로 내보낸 후 다시 시도하세요.'],
  photosUnavailable: ['Photo unavailable', '照片暂不可用', 'Photo indisponible', '写真を表示できません', '사진을 사용할 수 없습니다']
};
for (const [key, values] of Object.entries(photoStrings)) {
  Object.keys(supportedLanguages).forEach((code, index) => { catalog[code][key] = values[index]; });
}
const connectionStrings = {
  pairing: ['Connecting to your Mac…', '正在连接你的 Mac…', 'Connexion à votre Mac…', 'Mac に接続中…', 'Mac에 연결 중…'],
  quickLANNote: ['Direct Wi-Fi connection. Use a trusted private network; this connection is not encrypted.', '通过局域网直接连接，请使用可信的私人网络；此连接未加密。', 'Connexion Wi-Fi directe. Utilisez un réseau privé de confiance ; cette connexion n’est pas chiffrée.', 'Wi-Fi で直接接続します。信頼できるプライベートネットワークで使用してください。この接続は暗号化されません。', 'Wi-Fi로 직접 연결합니다. 신뢰할 수 있는 사설 네트워크를 사용하세요. 이 연결은 암호화되지 않습니다.'],
  installAndroidLAN: ['Use Add to home screen or a bookmark in your browser menu to save this address as a shortcut.', '可在浏览器菜单中选择「添加到主屏幕」或收藏，将此地址保存为网页快捷方式。', 'Utilisez Ajouter à l’écran d’accueil ou les favoris du navigateur pour enregistrer un raccourci vers cette adresse.', 'ブラウザーのメニューで「ホーム画面に追加」またはブックマークを選び、このアドレスへのショートカットを保存できます。', '브라우저 메뉴에서 홈 화면에 추가 또는 북마크를 선택하여 이 주소의 바로가기를 저장하세요.'],
  installNetworkLAN: ['Keep your phone and Mac on the same Wi-Fi, with TheAll running and your Mac awake. This shortcut needs a live connection and has no offline mode. Scan again if your Mac’s address changes.', '请保持手机与 Mac 在同一 Wi-Fi，Mac 唤醒且 TheAll 正在运行。快捷方式需要在线连接，不提供离线模式；Mac 地址改变后请重新扫码。', 'Gardez votre téléphone et votre Mac sur le même Wi-Fi, avec TheAll ouvert et le Mac éveillé. Le raccourci nécessite une connexion active et ne fonctionne pas hors ligne. Scannez à nouveau si l’adresse du Mac change.', 'スマートフォンと Mac を同じ Wi-Fi に接続し、Mac をスリープさせず TheAll を起動しておいてください。このショートカットはオンライン接続が必要で、オフラインでは使えません。Mac のアドレスが変わったら再度スキャンしてください。', '휴대전화와 Mac을 같은 Wi-Fi에 연결하고 Mac을 깨운 상태로 TheAll을 실행하세요. 바로가기는 온라인 연결이 필요하며 오프라인 모드는 없습니다. Mac 주소가 바뀌면 다시 스캔하세요.'],
};
for (const [key, values] of Object.entries(connectionStrings)) {
  Object.keys(supportedLanguages).forEach((code, index) => { catalog[code][key] = values[index]; });
}
const notificationStrings = {
  effortConfirmed: ['CLI confirmed effort', 'CLI 已确认强度', 'Effort confirmé par le CLI', 'CLI 確認済みの強度', 'CLI가 확인한 강도'],
  effortRequested: ['Requested effort', '请求强度', 'Effort demandé', '要求した強度', '요청한 강도'],
  reasoningEffort: ['Reasoning effort', '思考强度', 'Effort de raisonnement', '思考の強度', '추론 강도'],
  defaultEffort: ['Default effort', '默认强度', 'Effort par défaut', '既定の強度', '기본 강도'],
  effortUnavailable: ['This model has not provided selectable effort levels yet.', '当前模型尚未提供可选的思考强度，暂时无法更改。', 'Ce modèle ne fournit pas encore de niveaux d’effort sélectionnables.', 'このモデルは選択可能な思考の強度をまだ提供していません。', '이 모델은 아직 선택 가능한 추론 강도를 제공하지 않습니다.'],
  effort_none: ['None', '无', 'Aucun', 'なし', '없음'],
  effort_minimal: ['Minimal', '极低', 'Minimal', '最小', '최소'],
  effort_low: ['Low', '低', 'Faible', '低', '낮음'],
  effort_medium: ['Medium', '中', 'Moyen', '中', '중간'],
  effort_high: ['High', '高', 'Élevé', '高', '높음'],
  effort_xhigh: ['Very high', '极高', 'Très élevé', '非常に高い', '매우 높음'],
  effort_max: ['Maximum', '最高', 'Maximum', '最大', '최대'],
  turnFailedAt: ['Failed', '失败于', 'Échec à', '失敗', '실패'],
  turnInterruptedAt: ['Stopped', '停止于', 'Arrêté à', '停止', '중지'],
  notificationsTitle: ['Task completion alerts', '任务完成提醒', 'Alertes de fin de tâche', 'タスク完了通知', '작업 완료 알림'],
  notificationsHelp: ['Receive completion alerts on your phone and paired watch. Watch delivery follows your device’s notification and Focus settings.', '在手机及配对手表上接收任务完成提醒。手表提醒遵循系统通知和专注模式设置。', 'Recevez les alertes de fin de tâche sur votre téléphone et votre montre jumelée. Leur affichage dépend des réglages de notification et de concentration.', 'スマートフォンとペアリングした時計で完了通知を受け取れます。時計への通知は端末の通知・集中モード設定に従います。', '휴대전화와 페어링된 시계에서 완료 알림을 받을 수 있습니다. 시계 알림은 기기의 알림 및 집중 모드 설정을 따릅니다.'],
  notificationsHTTPS: ['Background alerts require HTTPS. Use encrypted HTTPS or an HTTPS relay in the desktop phone-connection settings, then reopen that address.', '后台提醒需要 HTTPS。请在桌面端手机连接设置中启用加密 HTTPS，或使用 HTTPS 中继，再打开对应地址。', 'Les alertes en arrière-plan nécessitent HTTPS. Activez HTTPS ou un relais HTTPS dans les réglages de connexion mobile sur l’ordinateur, puis ouvrez cette adresse.', 'バックグラウンド通知には HTTPS が必要です。デスクトップのスマートフォン接続設定で HTTPS または HTTPS 中継を有効にし、そのアドレスを開いてください。', '백그라운드 알림에는 HTTPS가 필요합니다. 데스크톱 휴대전화 연결 설정에서 HTTPS 또는 HTTPS 중계를 활성화한 뒤 해당 주소를 다시 여세요.'],
  notificationsInstall: ['On iPhone or iPad, add TheAll to your Home Screen and open it there before enabling alerts.', '在 iPhone 或 iPad 上，请先将 TheAll 添加到主屏幕，并从主屏幕打开后启用提醒。', 'Sur iPhone ou iPad, ajoutez TheAll à l’écran d’accueil et ouvrez-le depuis cet écran avant d’activer les alertes.', 'iPhone・iPad では TheAll をホーム画面に追加し、そこから開いて通知を有効にしてください。', 'iPhone 또는 iPad에서는 TheAll을 홈 화면에 추가하고 홈 화면에서 연 다음 알림을 활성화하세요.'],
  notificationsUnsupported: ['This browser does not support background push alerts. Use a supported mobile browser.', '此浏览器不支持后台推送提醒，请使用支持此功能的手机浏览器。', 'Ce navigateur ne prend pas en charge les notifications push en arrière-plan. Utilisez un navigateur mobile compatible.', 'このブラウザーはバックグラウンドのプッシュ通知に対応していません。対応するモバイルブラウザーをご利用ください。', '이 브라우저는 백그라운드 푸시 알림을 지원하지 않습니다. 지원되는 모바일 브라우저를 사용하세요.'],
  notificationsBlocked: ['Notifications are blocked. Allow TheAll notifications in your phone’s system or browser settings, then try again.', '通知权限已关闭。请在手机系统或浏览器设置中允许 TheAll 通知，再重试。', 'Les notifications sont bloquées. Autorisez celles de TheAll dans les réglages du téléphone ou du navigateur, puis réessayez.', '通知がブロックされています。端末またはブラウザーの設定で TheAll の通知を許可してから再試行してください。', '알림이 차단되어 있습니다. 휴대전화 또는 브라우저 설정에서 TheAll 알림을 허용한 뒤 다시 시도하세요.'],
  notificationsUpdate: ['Update the desktop app to use task-completion alerts. Conversations are still available.', '请更新桌面端以使用任务完成提醒，现有聊天仍可正常使用。', 'Mettez l’application de bureau à jour pour utiliser les alertes. Les conversations restent disponibles.', '完了通知を利用するにはデスクトップアプリを更新してください。会話は引き続き利用できます。', '완료 알림을 사용하려면 데스크톱 앱을 업데이트하세요. 대화는 계속 사용할 수 있습니다.'],
  notificationsUnavailable: ['Alerts are unavailable right now. Check the connection and try again.', '提醒暂时不可用，请检查连接后重试。', 'Les alertes sont momentanément indisponibles. Vérifiez la connexion et réessayez.', '現在通知を利用できません。接続を確認して再試行してください。', '현재 알림을 사용할 수 없습니다. 연결을 확인한 뒤 다시 시도하세요.'],
  notificationsEnabled: ['Task completion alerts are on for this device.', '此设备的任务完成提醒已开启。', 'Les alertes de fin de tâche sont activées sur cet appareil.', 'この端末のタスク完了通知は有効です。', '이 기기의 작업 완료 알림이 켜져 있습니다.'],
  notificationsDisabled: ['Task completion alerts are off for this device.', '此设备的任务完成提醒已关闭。', 'Les alertes de fin de tâche sont désactivées sur cet appareil.', 'この端末のタスク完了通知は無効です。', '이 기기의 작업 완료 알림이 꺼져 있습니다.'],
  notificationsEnable: ['Enable alerts', '开启提醒', 'Activer les alertes', '通知を有効にする', '알림 켜기'],
  notificationsDisable: ['Turn off alerts', '关闭提醒', 'Désactiver les alertes', '通知を無効にする', '알림 끄기'],
  notificationsTest: ['Send test alert', '发送测试提醒', 'Envoyer une alerte test', 'テスト通知を送信', '테스트 알림 보내기'],
  notificationsTestSent: ['Test alert sent. Delivery follows your phone and watch notification settings.', '测试提醒已发送，显示方式由手机和手表的通知设置决定。', 'Alerte test envoyée. Sa réception dépend des réglages du téléphone et de la montre.', 'テスト通知を送信しました。表示方法はスマートフォンと時計の通知設定に従います。', '테스트 알림을 보냈습니다. 표시 방식은 휴대전화와 시계의 알림 설정을 따릅니다.'],
  notificationsWorking: ['Updating alerts…', '正在更新提醒…', 'Mise à jour des alertes…', '通知を更新中…', '알림 업데이트 중…'],
  notificationsUnsubscribeFailed: ['Server alerts are off, but the browser subscription could not be removed. Try turning alerts off again.', '服务端提醒已关闭，但浏览器订阅未能移除，请再次关闭提醒。', 'Les alertes du serveur sont désactivées, mais l’abonnement du navigateur n’a pas pu être supprimé. Réessayez.', 'サーバーの通知は無効ですが、ブラウザーの購読を解除できませんでした。もう一度無効にしてください。', '서버 알림은 꺼졌지만 브라우저 구독을 제거하지 못했습니다. 다시 알림을 끄세요.'],
  notificationChatUnavailable: ['This notification’s conversation is no longer available to this device.', '此提醒对应的对话已不存在，或此设备没有访问权限。', 'La conversation de cette notification n’est plus accessible depuis cet appareil.', 'この通知の会話は削除されたか、この端末ではアクセスできません。', '이 알림의 대화가 더 이상 없거나 이 기기에서 접근할 수 없습니다.'],
  turnCompletedAt: ['Completed', '完成于', 'Terminé à', '完了', '완료'],
  turnDuration: ['Took', '耗时', 'Durée', '所要時間', '소요 시간']
};
for (const [key, values] of Object.entries(notificationStrings)) {
  Object.keys(supportedLanguages).forEach((code, index) => { catalog[code][key] = values[index]; });
}
export function resolveLanguage(value) {
  const lower = String(value || '').toLowerCase();
  return lower.startsWith('zh') ? 'zh-Hans' : Object.keys(supportedLanguages).find(key => lower.split('-')[0] === key) || 'en';
}
let current = resolveLanguage(globalThis.navigator?.language);
try { const saved = globalThis.window?.localStorage?.getItem('theall.language'); if (saved && supportedLanguages[saved]) current = saved; } catch { /* Private browsing may disable storage. */ }
export const language = () => current;
export function setLanguage(value) {
  if (!supportedLanguages[value]) return;
  current = value;
  try { globalThis.window?.localStorage?.setItem('theall.language', value); } catch { /* Switching still works in memory. */ }
}
export const t = key => catalog[current][key] || catalog.en[key] || key;
