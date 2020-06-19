import toxcore, toxcore/av, toxcore/bootstrap, opusenc, ulid

import std/asyncdispatch, std/asyncfile, std/os, std/random, std/strutils,
    std/tables, std/times, std/uri

{.passL: "-lcrypto".}

const
  readmeText = readFile "README.md"

proc saveFileName(): string =
  getEnv("TOX_DATA_FILE", "tox_save.tox")

proc conferenceTitle(): string =
  getEnv("TOX_CONFERENCE_TITLE", "Recorder group")

iterator adminIds(): Address =
  let admins = getEnv("TOX_ADMIN_ID")
  if admins == "":
    echo "Warning: no admins declared via $TOX_ADMIN_ID"
  for admin in splitWhitespace admins:
    yield admin.toAddress

type
  Recording = ref object
    comments: OggOpusComments
    encoder: OggOpusEnc
    path: string
    id: string

  Bot = ref object
    core: Tox
    av: ToxAv

proc addAdmin(bot: Bot; id: Address) =
  try:
    discard bot.core.addFriend(
      id, "You have been granted administrative rights to " & bot.core.name)
  except ToxError:
    discard

proc avatarPath(bot: Bot): string =
  getEnv("TOX_AVATAR_FILE", "avatars/self.png")

proc sendAvatar(bot: Bot; friend: Friend) =
  let path = bot.avatarPath()
  if existsFile path:
    let size = path.getFileSize
    if 65536 < size:
      echo "Error: ", path, " is larger than 64KiB"
    else:
      discard bot.core.send(
        friend, TOX_FILE_KIND_AVATAR.uint32,
        path.getFileSize, path)

proc sendAvatarChunk(bot: Bot; friend: Friend; file: FileTransfer; pos: uint64;
    size: int) {.async.} =
  let iconFile = openAsync(bot.avatarPath(), fmRead)
  iconFile.setFilePos(pos.int64);
  let chunk = await iconFile.read(size)
  close iconFile
  bot.core.sendChunk(friend, file, pos, chunk)

proc updateAvatar(bot: Bot) =
  for friend in bot.core.friends:
    if bot.core.connectionStatus(friend) != TOX_CONNECTION_NONE:
      bot.sendAvatar(friend)

type Command = enum
  help, invite, readme, newspam, revoke

proc updateStatus(bot: Bot) {.async.} =
  discard

proc initAudioRecording(bot: Bot; friend: Friend): Recording {.gcsafe.} =
  let
    id = ulid()
  result = Recording(
    comments: newComments(),
    id: id,
    path: getEnv("TOX_RECORDINGS_DIR", ".") / id & ".opus")
  result.comments.add("DATE", now().format("yyyy-MM-dd HH:mm"))
  result.comments.add("ULID", id)
  result.comments.add("TOX_FRIEND", bot.core.name(friend))
  result.comments.add("TOX_PUBLIC_KEY", $bot.core.publicKey(friend))
  result.comments.add("TOX_STATUS", $bot.core.statusMessage(friend))
  result.encoder = encoderCreateFile(result.path, result.comments, 48000, 2)

proc recordingUrl(rec: Recording): string =
  let format = getEnv("TOX_RECORDING_URL")
  if format == "":
    rec.path
  else:
    format % rec.id

proc firstWord(msg: string): string =
  var words = msg.split(' ')
  words[0].normalize

proc setup(bot: Bot) =
  addTimer(20*1000, oneshot = false) do (fd: AsyncFD) -> bool:
    asyncCheck updateStatus(bot)

  var
    friendRecordings = initTable[Friend, Recording]()

  let conference = bot.core.newConference()
  `title=`(bot.core, conference, conferenceTitle())

  proc closeRecording(friend: Friend) =
    var rec: Recording
    if friendRecordings.pop(friend, rec):
      drain rec.encoder
      destroy rec.encoder
      destroy rec.comments
      discard bot.core.send(friend,
        "finalized " & recordingUrl(rec),
        TOX_MESSAGE_TYPE_ACTION)

  bot.core.onSelfConnectionStatus do (status: Connection):
    case status
    of TOX_CONNECTION_NONE:
      echo("Disconnected from Tox network")
    of TOX_CONNECTION_TCP:
      echo("Acquired TCP connection to Tox network")
    of TOX_CONNECTION_UDP:
      echo("Acquired UDP connection to Tox network")

  bot.core.onFriendConnectionStatus do (friend: Friend; status: Connection):
    if status == TOX_CONNECTION_NONE:
      closeRecording(friend)
    else:
      bot.core.invite(friend, conference)
      bot.sendAvatar(friend)

  bot.core.onFriendRequest do (key: PublicKey; msg: string):
    echo key, ": ", msg
    discard bot.core.addFriendNoRequest(key)

  bot.core.onFriendMessage do (f: Friend; msg: string; kind: MessageType):
    proc reply(msg: string, kind = TOX_MESSAGE_TYPE_NORMAL) =
      discard bot.core.send(f, msg, kind)
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
          of newspam:
            reply(
              """Rotate bot toxid. """ &
              """This prevents any previously generated toxid to be used """ &
              """ to add new friends to the bot.""")
          of readme:
            reply """Return bot README"""
          of revoke:
            reply """Remove yourself from the bot roster."""

      of invite:
        if words[1] == "":
          echo bot.core.name, " is at ", bot.core.address
          reply($bot.core.address &
            " - pass this toxid to the friend you wish to invite."&
            " Use the `newspam` command to revoke this toxid."
            )
        else:
          for id in words[1..words.high]:
            try:
              discard bot.core.addFriend(id.toAddress,
                  "You have been invited to the $1 by $2 ($3)" % [bot.core.name,
                  bot.core.name(f), $bot.core.publicKey(f)])
              reply("invited " & id, TOX_MESSAGE_TYPE_ACTION)
            except:
              reply(getCurrentExceptionMsg())

      of newspam:
        let now = getTime()
        var rng = initRand(bot.core.noSpam.int64 xor now.toUnix xor now.nanosecond)
        bot.core.noSpam = (NoSpam)rng.rand(NoSpam.high.int)
        reply("rotated toxid to " & $bot.core.address, TOX_MESSAGE_TYPE_ACTION)

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

  bot.core.onConferenceInvite do (friend: Friend; kind: ConferenceType; cookie: string):
    discard bot.core.join(friend, cookie)

  bot.core.onConferenceConnected do (conf: Conference):
    echo "Connected to conference \"", bot.core.title(conf), "\""

  bot.av.onCall do (friend: Friend; audioEnabled, videoEnabled: bool):
    assert(not friendRecordings.hasKey(friend))
    if bot.av.answer(friend):
      friendRecordings[friend] = initAudioRecording(bot, friend)
      discard bot.core.send(friend,
        "records to file " & recordingUrl(friendRecordings[friend]),
        TOX_MESSAGE_TYPE_ACTION)

  bot.av.onCallState do (friend: Friend; state: uint32):
    if state == FRIEND_CALL_STATE_FINISHED:
      closeRecording(friend)

  bot.av.onAudioReceiveFrame do (
      friend: Friend; pcm: Samples; sampleCount: int;
      channels: uint8; sampleRate: uint32):
    doAssert(channels == 2)
    doAssert(sampleRate == 48000)
    let rec = friendRecordings[friend]
    rec.encoder.write(addr pcm[0], sampleCount)

    doAssert(channels == 2)

proc newBot(): Bot =
  let core = newTox do (opts: Options):
    opts.localDiscoveryEnabled = true
    opts.ipv6Enabled = true
    if existsFile saveFileName():
      opts.saveDataType = TOX_SAVEDATA_TYPE_TOX_SAVE
      opts.savedata = readFile(saveFileName())

  let av = newAv(core)

  result = Bot(core: core, av: av)
  result.core.name = getEnv("TOX_NAME", "Recorder Bot")
  result.core.statusMessage = getEnv("TOX_STATUS", "")

  result.setup()

  for id in adminIds(): result.addAdmin(id)

  asyncCheck result.core.bootstrapFromSpof()

  echo result.core.name, " is at ", result.core.address

  let ap = result.avatarPath()
  if not fileExists(ap):
    echo "Warning: no avatar found at ", ap

proc main() =
  let bot = newBot()
  writeFile(saveFileName(), bot.core.saveData)
  echo "DHT port and key: ", bot.core.udpPort, " ", bot.core.dhtId

  while true:
    iterate bot.core
    iterate bot.av
    poll(min(bot.core.iterationInterval, bot.av.iterationInterval))

main()
