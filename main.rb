#!/usr/bin/env ruby

require 'date'
require 'rubygems'
require 'telegram/bot'
require 'stringio'

require_relative 'dialog'
require_relative 'cache'
require_relative 'runners'


# Настройки
$config = {
  host: 'ftp.zakupki.gov.ru',

  # Логины/пароли разные для разных директорий.
  logpasses: [{
    prefix: /^\/out\//, user: 'fz223free', pass: 'fz223free',
  }, {
    prefix: /.*/, user: 'free', pass: 'free',
  }],

  max_messages_limit: 100,
  cache_path: '/tmp/cache',
  cache_size: 10,
}


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
            host: $config[:host],
            logpasses: $config[:logpasses],
            pass: $config[:pass],
            path: data[:path_or_name],
            dates: data[:dates],
            cache: DiskCacher.new($config[:cache_path], $config[:cache_size]),
          }, data[:queries])

          max_messages_limit = $config[:max_messages_limit]

          runner.run do |zip_name, xml_name, data|
            if max_messages_limit > 0
              bot.api.send_message(
                chat_id: message.chat.id,
                text: "ftp://#{$config[:host]}#{zip_name}\n#{xml_name}"
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
