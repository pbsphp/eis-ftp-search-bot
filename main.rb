#!/usr/bin/env ruby

require 'date'
require 'rubygems'
require 'telegram/bot'
require 'stringio'
require 'zip'

require_relative 'dialog'
require_relative 'cache'
require_relative 'runners'

# Загружаем настройки из файла setings.rb если есть. Если нет, то
# из дефолтного.
begin
  require_relative 'settings.rb'
rescue LoadError
  require_relative 'settings.default.rb'
end


# Отключить предупреждения о кривых датах.
Zip.warn_invalid_date = false


token_path = File.join(File.dirname(__FILE__), '.token')
unless File.exists?(token_path)
  abort(
    "fatal: Token file is missing!\n" +
    "Put `.token' with telegram bot token into project root."
  )
end
tg_token = File.read(token_path).strip


Telegram::Bot::Client.run(tg_token) do |bot|
  bot.listen do |message|
    case message.text
    when '/start'
      dialog = Dialog.new
      Dialog.dialogs[message.chat.id] = dialog
      reply = dialog.receive(message.text)
      bot.api.send_message(chat_id: message.chat.id, text: reply)

    when '/about'
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "TODO"
      )

    else
      dialog = Dialog.dialogs[message.chat.id]
      if dialog.nil?
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Используй /start чтобы начать."
        )
      else
        reply = dialog.receive(message.text)
        if dialog.complete?
          data = dialog.data
          msg = %Q$
            Ищем здесь: #{data[:path_or_name]},
            за #{data[:dates][0] or '*'} - #{data[:dates][1] or '*'},
            подстроки: #{data[:queries].join ' / '}...
          $.gsub(/\s+/, " ").strip
          bot.api.send_message(chat_id: message.chat.id, text: msg)

          Dialog.dialogs[message.chat.id] = nil

          # Начинаем обработку.
          runner = XmlRunner.new({
            host: Settings::HOST,
            logpasses: Settings::LOGPASSES,
            path: data[:path_or_name],
            dates: data[:dates],
            cache: DiskCacher.new(Settings::CACHE_PATH, Settings::CACHE_SIZE),
          }, data[:queries])

          max_messages_limit = Settings::MAX_MESSAGES_LIMIT

          runner.run do |zip_name, xml_name, data|
            if max_messages_limit > 0
              bot.api.send_message(
                chat_id: message.chat.id,
                text: "ftp://#{Settings::HOST}#{zip_name}\n#{xml_name}"
              )
              bot.api.send_document(
                chat_id: message.chat.id,
                document:
                  Faraday::UploadIO.new(StringIO.new(data), 'text/xml', xml_name),
                disable_notification: true,
              )

              max_messages_limit -= 1
            end
          end

          bot.api.send_message(chat_id: message.chat.id, text: 'Все.')
        else
          bot.api.send_message(chat_id: message.chat.id, text: reply)
        end
      end
    end
  end
end
