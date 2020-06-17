import toxcore, toxcore/av, opusenc

import std/asyncdispatch, std/asyncfile, std/json, std/os, std/strutils,
    std/tables, std/times, std/uri

{.passL: "-lcrypto".}

const
  readmeText = readFile "README.md"

proc saveFileName(): string =
  getEnv("TOX_DATA_FILE", "recorder.toxdata")

proc iconFilename(): string =
  getEnv("TOX_AVATAR_FILE", "avatar.png")

proc conferenceTitle(): string =
  getEnv("TOX_CONFERENCE_TITLE", "Recorder group")

proc recordingsDir(): string =
  getEnv("TOX_RECORDINGS_DIR", ".")

iterator adminIds(): Address =
  let admins = getEnv("TOX_ADMIN_ID", "DF0AC9107E0A30E7201C6832B017AC836FBD1EDAC390EE99B68625D73C3FD929FB47F1872CA4")
  for admin in splitWhitespace admins:
    yield admin.toAddress

type
  FriendState = ref object
    comments: OggOpusComments
    encoder: OggOpusEnc

  Bot = ref object
    core: Tox
    av: ToxAv
    state: Table[Friend, FriendState]

proc bootstrap(bot: Bot) =
  const servers = [
    ("::1",
      "5533D825BA28D2D0A4F8CF1205EC7E7A506994081B52595DFE112C6A4AC14668".toPublicKey
    )
  ]
  for host, key in servers.items:
    bot.core.bootstrap(host, key)

proc addAdmin(bot: Bot; id: Address) =
  try:
    discard bot.core.addFriend(
      id, "You have been granted administrative rights to " & bot.core.name)
  except ToxError:
    discard

proc sendAvatar(bot: Bot; friend: Friend) =
  let path = iconFilename()
  if existsFile path:
    discard bot.core.send(
      friend, TOX_FILE_KIND_AVATAR.uint32,
      path.getFileSize, path)

proc sendAvatarChunk(bot: Bot; friend: Friend; file: FileTransfer; pos: uint64;
    size: int) {.async.} =
  let iconFile = openAsync(iconFilename(), fmRead)
  iconFile.setFilePos(pos.int64);
  let chunk = await iconFile.read(size)
  close iconFile
  bot.core.sendChunk(friend, file, pos, chunk)

proc updateAvatar(bot: Bot) =
  for friend in bot.core.friends:
    if bot.core.connectionStatus(friend) != TOX_CONNECTION_NONE:
      bot.sendAvatar(friend)

type Command = enum
  help, invite, readme, revoke

proc updateStatus(bot: Bot) {.async.} =
  discard

proc closeState(bot: Bot; friend: Friend) =
  if bot.state.hasKey friend:
    let state = bot.state[friend]
    bot.state.del friend
    drain state.encoder
    destroy state.encoder
    destroy state.comments

proc setup(bot: Bot) =
  addTimer(20*1000, oneshot = false) do (fd: AsyncFD) -> bool:
    asyncCheck updateStatus(bot)

  let conference = bot.core.newConference()
  `title=`(bot.core, conference, conferenceTitle())

  bot.core.onFriendConnectionStatus do (friend: Friend; status: Connection):
    if status == TOX_CONNECTION_NONE:
      bot.closeState(friend)
    else:
      bot.core.invite(friend, conference)
      bot.sendAvatar(friend)

  bot.core.onFriendMessage do (f: Friend; msg: string; kind: MessageType):
    proc reply(msg: string) =
      discard bot.core.send(f, msg)
    try:
      var words = msg.split(' ')
      if words.len < 1:
        words.add "help"
      if words.len < 2:
        words.add ""

      case parseEnum[Command](words[0].normalize)

      of help:
        var cmd = help
        if words[1] != "":
          try: cmd = parseEnum[Command](words[1].normalize)
          except:
            reply("$1 is not a help topic" % words[1])
        case cmd:
          of help:
            var resp = """Return help message for the following commands:"""
            for e in Command:
              resp.add "\n\t"
              resp.add $e
            reply(resp)
          of invite:
            reply """Invite a new user to the bot."""
          of readme:
            reply """Return bot README"""
          of revoke:
            reply """Remove yourself from the bot roster."""

      of invite:
        for id in words[1..words.high]:
          try:
            discard bot.core.addFriend(id.toAddress,
                "You have been invited to the $1 by $2 ($3)" % [bot.core.name,
                bot.core.name(f), $bot.core.publicKey(f)])
          except:
            reply(getCurrentExceptionMsg())

      of readme:
        reply readmeText

      of revoke:
        reply """Tchuss"""
        discard bot.core.delete(f)

    except:
      reply(getCurrentExceptionMsg())

  bot.core.onFileChunkRequest do (friend: Friend; file: FileTransfer;
      pos: uint64; size: int):
    if size != 0:
      asyncCheck bot.sendAvatarChunk(friend, file, pos, size)

  bot.av.onCall do (friend: Friend; audioEnabled, videoEnabled: bool):
    proc reply(msg: string) =
      discard bot.core.send(friend, msg)
    if audioEnabled: reply "calling with audio"
    if videoEnabled: reply "calling with video"
    assert(not bot.state.hasKey(friend))
    if bot.av.answer(friend):
      let
        date = now().format("yyyy-MM-dd-hh:mm:ss")
        path = recordingsDir() / date & ".opus"
        state = FriendState(comments: newComments())
      bot.state[friend] = state
      state.comments.add("DATE", date)
      state.comments.add("TOX_FRIEND", bot.core.name(friend))
      state.comments.add("TOX_PUBLIC_KEY", $bot.core.publicKey(friend))
      state.comments.add("TOX_STATUS", $bot.core.statusMessage(friend))
      state.encoder = encoderCreateFile(path, state.comments, 48000, 2)
      reply("recording to file " & path)

  bot.av.onCallState do (friend: Friend; state: uint32):
    if state == FRIEND_CALL_STATE_FINISHED:
      bot.closeState(friend)

  bot.av.onAudioReceiveFrame do (
      friend: Friend; pcm: Samples; sampleCount: int;
      channels: uint8; samplingRate: uint32):
    doAssert(channels == 2)
    doAssert(samplingRate == 48000)
    let state = bot.state[friend]
    state.encoder.write(addr pcm[0], sampleCount)

proc newBot(): Bot =
  let core = newTox do (opts: Options):
    opts.localDiscoveryEnabled = true
    opts.ipv6Enabled = true
    if existsFile saveFileName():
      opts.saveDataType = TOX_SAVEDATA_TYPE_TOX_SAVE
      opts.savedata = readFile(saveFileName())

  let av = newAv(core)

  result = Bot(core: core, av: av, state: initTable[Friend, FriendState]())
  result.core.name = getEnv("TOX_NAME", "Recorder Bot")
  result.core.statusMessage = getEnv("TOX_STATUS", "")

  result.setup()

  for id in adminIds(): result.addAdmin(id)
  result.bootstrap()
  echo result.core.name, " is at ", result.core.address

proc main() =
  let bot = newBot()
  writeFile(saveFileName(), bot.core.saveData)
  echo "DHT port and key: ", bot.core.udpPort, " ", bot.core.dhtId

  while true:
    iterate bot.core
    iterate bot.av
    poll(min(bot.core.iterationInterval, bot.av.iterationInterval))

main()
