import 'dart:async';
import 'dart:collection';

import 'package:appflowy/plugins/ai_chat/application/chat_message_stream.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-ai/entities.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-error/code.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-user/user_profile.pb.dart';
import 'package:collection/collection.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:nanoid/nanoid.dart';

import 'chat_entity.dart';
import 'chat_message_listener.dart';
import 'chat_message_service.dart';

part 'chat_bloc.freezed.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required ViewPB view,
    required UserProfilePB userProfile,
  })  : listener = ChatMessageListener(chatId: view.id),
        chatId = view.id,
        super(
          ChatState.initial(view, userProfile),
        ) {
    _startListening();
    _dispatch();
  }

  final ChatMessageListener listener;
  final String chatId;

  /// The last streaming message id
  String answerStreamMessageId = '';
  String questionStreamMessageId = '';

  /// Using a temporary map to associate the real message ID with the last streaming message ID.
  ///
  /// When a message is streaming, it does not have a real message ID. To maintain the relationship
  /// between the real message ID and the last streaming message ID, we use this map to store the associations.
  ///
  /// This map will be updated when receiving a message from the server and its author type
  /// is 3 (AI response).
  final HashMap<String, String> temporaryMessageIDMap = HashMap();

  @override
  Future<void> close() async {
    if (state.answerStream != null) {
      await state.answerStream?.dispose();
    }
    await listener.stop();
    return super.close();
  }

  void _dispatch() {
    on<ChatEvent>(
      (event, emit) async {
        await event.when(
          initialLoad: () {
            final payload = LoadNextChatMessagePB(
              chatId: state.view.id,
              limit: Int64(10),
            );
            AIEventLoadNextMessage(payload).send().then(
              (result) {
                result.fold((list) {
                  if (!isClosed) {
                    final messages =
                        list.messages.map(_createTextMessage).toList();
                    add(ChatEvent.didLoadLatestMessages(messages));
                  }
                }, (err) {
                  Log.error("Failed to load messages: $err");
                });
              },
            );
          },
          // Loading messages
          startLoadingPrevMessage: () async {
            Int64? beforeMessageId;
            final oldestMessage = _getOldestMessage();
            if (oldestMessage != null) {
              try {
                beforeMessageId = Int64.parseInt(oldestMessage.id);
              } catch (e) {
                Log.error(
                  "Failed to parse message id: $e, messaeg_id: ${oldestMessage.id}",
                );
              }
            }
            _loadPrevMessage(beforeMessageId);
            emit(
              state.copyWith(
                loadingPreviousStatus: const ChatLoadingState.loading(),
              ),
            );
          },
          didLoadPreviousMessages: (List<Message> messages, bool hasMore) {
            Log.debug("did load previous messages: ${messages.length}");
            final onetimeMessages = _getOnetimeMessages();
            final allMessages = _permanentMessages();
            final uniqueMessages = {...allMessages, ...messages}.toList();

            uniqueMessages.insertAll(0, onetimeMessages);

            emit(
              state.copyWith(
                messages: uniqueMessages,
                loadingPreviousStatus: const ChatLoadingState.finish(),
                hasMorePrevMessage: hasMore,
              ),
            );
          },
          didLoadLatestMessages: (List<Message> messages) {
            final onetimeMessages = _getOnetimeMessages();
            final allMessages = _permanentMessages();
            final uniqueMessages = {...allMessages, ...messages}.toList();
            uniqueMessages.insertAll(0, onetimeMessages);
            emit(
              state.copyWith(
                messages: uniqueMessages,
                initialLoadingStatus: const ChatLoadingState.finish(),
              ),
            );
          },
          // streaming message
          finishAnswerStreaming: () {
            emit(
              state.copyWith(
                streamingState: const StreamingState.done(),
                acceptRelatedQuestion: true,
                canSendMessage:
                    state.sendingState == const SendMessageState.done(),
              ),
            );
          },
          didUpdateAnswerStream: (AnswerStream stream) {
            emit(state.copyWith(answerStream: stream));
          },
          stopStream: () async {
            if (state.answerStream == null) {
              return;
            }

            final payload = StopStreamPB(chatId: chatId);
            await AIEventStopStream(payload).send();
            final allMessages = _permanentMessages();
            if (state.streamingState != const StreamingState.done()) {
              // If the streaming is not started, remove the message from the list
              if (!state.answerStream!.hasStarted) {
                allMessages.removeWhere(
                  (element) => element.id == answerStreamMessageId,
                );
                answerStreamMessageId = "";
              }

              // when stop stream, we will set the answer stream to null. Which means the streaming
              // is finished or canceled.
              emit(
                state.copyWith(
                  messages: allMessages,
                  answerStream: null,
                  streamingState: const StreamingState.done(),
                ),
              );
            }
          },
          receiveMessage: (Message message) {
            final allMessages = _permanentMessages();
            // remove message with the same id
            allMessages.removeWhere((element) => element.id == message.id);
            allMessages.insert(0, message);
            emit(
              state.copyWith(
                messages: allMessages,
              ),
            );
          },
          startAnswerStreaming: (Message message) {
            final allMessages = _permanentMessages();
            allMessages.insert(0, message);
            emit(
              state.copyWith(
                messages: allMessages,
                streamingState: const StreamingState.streaming(),
                canSendMessage: false,
              ),
            );
          },
          sendMessage: (String message, Map<String, dynamic>? metadata) async {
            unawaited(_startStreamingMessage(message, metadata, emit));
            final allMessages = _permanentMessages();
            emit(
              state.copyWith(
                lastSentMessage: null,
                messages: allMessages,
                relatedQuestions: [],
                acceptRelatedQuestion: false,
                sendingState: const SendMessageState.sending(),
                canSendMessage: false,
              ),
            );
          },
          finishSending: (ChatMessagePB message) {
            emit(
              state.copyWith(
                lastSentMessage: message,
                sendingState: const SendMessageState.done(),
                canSendMessage:
                    state.streamingState == const StreamingState.done(),
              ),
            );
          },
          failedSending: () {
            emit(
              state.copyWith(
                messages: _permanentMessages()..removeAt(0),
                sendingState: const SendMessageState.done(),
                canSendMessage: true,
              ),
            );
          },
          // related question
          didReceiveRelatedQuestion: (List<RelatedQuestionPB> questions) {
            if (questions.isEmpty) {
              return;
            }

            final allMessages = _permanentMessages();
            final message = CustomMessage(
              metadata: OnetimeShotType.relatedQuestion.toMap(),
              author: const User(id: systemUserId),
              showStatus: false,
              id: systemUserId,
            );
            allMessages.insert(0, message);
            emit(
              state.copyWith(
                messages: allMessages,
                relatedQuestions: questions,
              ),
            );
          },
          clearRelatedQuestions: () {
            emit(
              state.copyWith(
                relatedQuestions: [],
              ),
            );
          },
        );
      },
    );
  }

  void _startListening() {
    listener.start(
      chatMessageCallback: (pb) {
        if (!isClosed) {
          // 3 mean message response from AI
          if (pb.authorType == 3 && answerStreamMessageId.isNotEmpty) {
            temporaryMessageIDMap[pb.messageId.toString()] =
                answerStreamMessageId;
            answerStreamMessageId = "";
          }

          // 1 mean message response from User
          if (pb.authorType == 1 && questionStreamMessageId.isNotEmpty) {
            temporaryMessageIDMap[pb.messageId.toString()] =
                questionStreamMessageId;
            questionStreamMessageId = "";
          }

          final message = _createTextMessage(pb);
          add(ChatEvent.receiveMessage(message));
        }
      },
      chatErrorMessageCallback: (err) {
        if (!isClosed) {
          Log.error("chat error: ${err.errorMessage}");
          add(const ChatEvent.finishAnswerStreaming());
        }
      },
      latestMessageCallback: (list) {
        if (!isClosed) {
          final messages = list.messages.map(_createTextMessage).toList();
          add(ChatEvent.didLoadLatestMessages(messages));
        }
      },
      prevMessageCallback: (list) {
        if (!isClosed) {
          final messages = list.messages.map(_createTextMessage).toList();
          add(ChatEvent.didLoadPreviousMessages(messages, list.hasMore));
        }
      },
      finishStreamingCallback: () {
        if (!isClosed) {
          add(const ChatEvent.finishAnswerStreaming());
          // The answer strema will bet set to null after the streaming is finished or canceled.
          // so if the answer stream is null, we will not get related question.
          if (state.lastSentMessage != null && state.answerStream != null) {
            final payload = ChatMessageIdPB(
              chatId: chatId,
              messageId: state.lastSentMessage!.messageId,
            );
            //  When user message was sent to the server, we start gettting related question
            AIEventGetRelatedQuestion(payload).send().then((result) {
              if (!isClosed) {
                result.fold(
                  (list) {
                    if (state.acceptRelatedQuestion) {
                      add(ChatEvent.didReceiveRelatedQuestion(list.items));
                    }
                  },
                  (err) {
                    Log.error("Failed to get related question: $err");
                  },
                );
              }
            });
          }
        }
      },
    );
  }

// Returns the list of messages that are not include one-time messages.
  List<Message> _permanentMessages() {
    final allMessages = state.messages.where((element) {
      return !(element.metadata?.containsKey(onetimeShotType) == true);
    }).toList();

    return allMessages;
  }

  List<Message> _getOnetimeMessages() {
    final messages = state.messages.where((element) {
      return (element.metadata?.containsKey(onetimeShotType) == true);
    }).toList();

    return messages;
  }

  Message? _getOldestMessage() {
    // get the last message that is not a one-time message
    final message = state.messages.lastWhereOrNull((element) {
      return !(element.metadata?.containsKey(onetimeShotType) == true);
    });
    return message;
  }

  void _loadPrevMessage(Int64? beforeMessageId) {
    final payload = LoadPrevChatMessagePB(
      chatId: state.view.id,
      limit: Int64(10),
      beforeMessageId: beforeMessageId,
    );
    AIEventLoadPrevMessage(payload).send();
  }

  Future<void> _startStreamingMessage(
    String message,
    Map<String, dynamic>? metadata,
    Emitter<ChatState> emit,
  ) async {
    if (state.answerStream != null) {
      await state.answerStream?.dispose();
    }

    final answerStream = AnswerStream();
    final questionStream = QuestionStream();
    add(ChatEvent.didUpdateAnswerStream(answerStream));

    final payload = StreamChatPayloadPB(
      chatId: state.view.id,
      message: message,
      messageType: ChatMessageTypePB.User,
      questionStreamPort: Int64(questionStream.nativePort),
      answerStreamPort: Int64(answerStream.nativePort),
      metadata: await metadataPBFromMetadata(metadata),
    );

    final questionStreamMessage = _createQuestionStreamMessage(
      questionStream,
      metadata,
    );
    add(ChatEvent.receiveMessage(questionStreamMessage));

    // Stream message to the server
    final result = await AIEventStreamMessage(payload).send();
    result.fold(
      (ChatMessagePB question) {
        if (!isClosed) {
          add(ChatEvent.finishSending(question));

          // final message = _createTextMessage(question);
          // add(ChatEvent.receiveMessage(message));

          final streamAnswer =
              _createAnswerStreamMessage(answerStream, question.messageId);
          add(ChatEvent.startAnswerStreaming(streamAnswer));
        }
      },
      (err) {
        if (!isClosed) {
          Log.error("Failed to send message: ${err.msg}");
          final metadata = OnetimeShotType.invalidSendMesssage.toMap();
          if (err.code != ErrorCode.Internal) {
            metadata[sendMessageErrorKey] = err.msg;
          }

          final error = CustomMessage(
            metadata: metadata,
            author: const User(id: systemUserId),
            showStatus: false,
            id: systemUserId,
          );

          add(const ChatEvent.failedSending());
          add(ChatEvent.receiveMessage(error));
        }
      },
    );
  }

  Message _createAnswerStreamMessage(
    AnswerStream stream,
    Int64 questionMessageId,
  ) {
    final streamMessageId = (questionMessageId + 1).toString();
    answerStreamMessageId = streamMessageId;

    return TextMessage(
      author: User(id: "streamId:${nanoid()}"),
      metadata: {
        "$AnswerStream": stream,
        messageQuestionIdKey: questionMessageId,
        "chatId": chatId,
      },
      id: streamMessageId,
      showStatus: false,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      text: '',
    );
  }

  Message _createQuestionStreamMessage(
    QuestionStream stream,
    Map<String, dynamic>? sentMetadata,
  ) {
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    questionStreamMessageId = timestamp.toString();
    final Map<String, dynamic> metadata = {};

    // if (sentMetadata != null) {
    //   metadata[messageMetadataJsonStringKey] = sentMetadata;
    // }

    metadata["$QuestionStream"] = stream;
    metadata["chatId"] = chatId;
    metadata[messageChatFileListKey] =
        chatFilesFromMessageMetadata(sentMetadata);
    return TextMessage(
      author: User(id: state.userProfile.id.toString()),
      metadata: metadata,
      id: questionStreamMessageId,
      showStatus: false,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      text: '',
    );
  }

  Message _createTextMessage(ChatMessagePB message) {
    String messageId = message.messageId.toString();

    /// If the message id is in the temporary map, we will use the previous fake message id
    if (temporaryMessageIDMap.containsKey(messageId)) {
      messageId = temporaryMessageIDMap[messageId]!;
    }

    return TextMessage(
      author: User(id: message.authorId),
      id: messageId,
      text: message.content,
      createdAt: message.createdAt.toInt() * 1000,
      showStatus: false,
      metadata: {
        messageRefSourceJsonStringKey: message.metadata,
      },
    );
  }
}

@freezed
class ChatEvent with _$ChatEvent {
  const factory ChatEvent.initialLoad() = _InitialLoadMessage;

  // send message
  const factory ChatEvent.sendMessage({
    required String message,
    Map<String, dynamic>? metadata,
  }) = _SendMessage;
  const factory ChatEvent.finishSending(ChatMessagePB message) =
      _FinishSendMessage;
  const factory ChatEvent.failedSending() = _FailSendMessage;

// receive message
  const factory ChatEvent.startAnswerStreaming(Message message) =
      _StartAnswerStreaming;
  const factory ChatEvent.receiveMessage(Message message) = _ReceiveMessage;
  const factory ChatEvent.finishAnswerStreaming() = _FinishAnswerStreaming;

// loading messages
  const factory ChatEvent.startLoadingPrevMessage() = _StartLoadPrevMessage;
  const factory ChatEvent.didLoadPreviousMessages(
    List<Message> messages,
    bool hasMore,
  ) = _DidLoadPreviousMessages;
  const factory ChatEvent.didLoadLatestMessages(List<Message> messages) =
      _DidLoadMessages;

// related questions
  const factory ChatEvent.didReceiveRelatedQuestion(
    List<RelatedQuestionPB> questions,
  ) = _DidReceiveRelatedQueston;
  const factory ChatEvent.clearRelatedQuestions() = _ClearRelatedQuestions;

  const factory ChatEvent.didUpdateAnswerStream(
    AnswerStream stream,
  ) = _DidUpdateAnswerStream;
  const factory ChatEvent.stopStream() = _StopStream;
}

@freezed
class ChatState with _$ChatState {
  const factory ChatState({
    required ViewPB view,
    required List<Message> messages,
    required UserProfilePB userProfile,
    // When opening the chat, the initial loading status will be set as loading.
    //After the initial loading is done, the status will be set as finished.
    required ChatLoadingState initialLoadingStatus,
    // When loading previous messages, the status will be set as loading.
    // After the loading is done, the status will be set as finished.
    required ChatLoadingState loadingPreviousStatus,
    // When sending a user message, the status will be set as loading.
    // After the message is sent, the status will be set as finished.
    required StreamingState streamingState,
    required SendMessageState sendingState,
    // Indicate whether there are more previous messages to load.
    required bool hasMorePrevMessage,
    // The related questions that are received after the user message is sent.
    required List<RelatedQuestionPB> relatedQuestions,
    @Default(false) bool acceptRelatedQuestion,
    // The last user message that is sent to the server.
    ChatMessagePB? lastSentMessage,
    AnswerStream? answerStream,
    @Default(true) bool canSendMessage,
  }) = _ChatState;

  factory ChatState.initial(ViewPB view, UserProfilePB userProfile) =>
      ChatState(
        view: view,
        messages: [],
        userProfile: userProfile,
        initialLoadingStatus: const ChatLoadingState.finish(),
        loadingPreviousStatus: const ChatLoadingState.finish(),
        streamingState: const StreamingState.done(),
        sendingState: const SendMessageState.done(),
        hasMorePrevMessage: true,
        relatedQuestions: [],
      );
}

bool isOtherUserMessage(Message message) {
  return message.author.id != aiResponseUserId &&
      message.author.id != systemUserId &&
      !message.author.id.startsWith("streamId:");
}
