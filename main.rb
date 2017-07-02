#!/usr/bin/env ruby

require 'date'
require 'net/ftp'
require 'rubygems'
require 'zip'
require 'telegram/bot'
require 'stringio'
require 'yaml/store'
require 'securerandom'


# Настройки
$config = {
  host: 'ftp.zakupki.gov.ru',
  logpasses: [{
    prefix: /^\/out\//, user: 'fz223free', pass: 'fz223free',
  }, {
    prefix: /.*/, user: 'free', pass: 'free',
  }],

  max_messages_limit: 100,
  cache_path: '/tmp/cache',
  cache_size: 10,
}


# Глобальный стейт диалогов.
# ... ну а куда еще...
$dialogs = {}


# Диалог. Позволяет хранить состояние диалога с пользователем.
# Посредством вызова receive(message) происходит общение до тех пор,
# пока пользователь не введет все необходимые данные.
# Пример использования:
# loop do
#   msg = gets.chomp
#   reply = d.receive(msg)
#   puts reply if reply
#   p d.data if d.complete?
# end
class Dialog

  attr_accessor :data

  def initialize
    # Собранные в процессе диалога данные.
    # Ключи берутся из @request_for.
    @data = {}

    # Список того, что нужно узнать у пользователя.
    # 1 - ключ для data;
    # 2 - Фраза для пользователя;
    # 3 - Парсер.
    # Парсер получает на вход строку - ответ пользователя, возвращает
    # обработанные данные или nil в случае некорректных данных.
    @request_for = [
      [
        :path_or_name,
        'Что (где) искать?',
        lambda { |x| path_name_parser(x) }
      ], [
        :dates,
        'С какого по какое? (ДД.ММ.ГГГГ - ДД.ММ.ГГГГ, можно оставлять пустым)',
        lambda { |x| dates_parser(x) }
      ], [
        :queries,
        'Что искать? (Через запятую)',
        lambda { |x| queries_parser(x) }
      ],
    ]

    # Состояние. Хранит один из элементов @request_for, на который в данный
    # момент ожидается ответ от пользователя.
    @answer_to = nil
  end

  def receive(message)
    if @answer_to
      key, question, parser = @answer_to
      nice_message = parser.call(message)
      return question if nice_message.nil?
      @data[key] = nice_message
    end

    if not @request_for.empty?
      key, question, parser = @request_for.shift
      @answer_to = [key, question, parser]
      question
    else
      @answer_to = nil
    end
  end

  # Диалог окончен - получены ответы на все вопросы.
  def complete?
    @request_for.empty? and @answer_to.nil?
  end

  protected

  # Парсит - где искать данные.
  def path_name_parser(data)
    case data
    when /пз|планы.?закупок/i
      '/fcs_regions/Tatarstan_Resp/purchaseplans/'
    when /пг|план.?график|планы.?графики/i
      '/fcs_regions/Tatarstan_Resp/plangraphs2017/'
    when /извещени/i
      '/fcs_regions/Tatarstan_Resp/notifications/'
    when /контракт/i
      '/fcs_regions/Tatarstan_Resp/contracts/'
    when /протокол/i
      '/fcs_regions/Tatarstan_Resp/protocols/'
    else
      # Ждем полный путь
      data =~ /^\// ? data : nil
    end
  end

  # Парсит диапазон дат (искать с - искать по)
  def dates_parser(data)
    pattern = %r{
      ^
      ([\w\.\-]+)?  # вервая дата
      \s*-\s*
      ([\w\.\-]+)?  # вторая дата
      $
    }x

    matches = pattern.match(data.strip)
    return nil if matches.nil?
    date_from, date_to = matches.captures

    begin
      date_from = Date.parse(date_from) if date_from
      date_to = Date.parse(date_to) if date_to
    rescue ArgumentError
      return nil
    end
    [date_from, date_to]
  end

  # Парсит список ключевых слов
  def queries_parser(data)
    data.split(',').map { |x| x.strip }
  end
end


# Простой дисковый LRU кэш.
# Общий принцип действия: есть hash-таблица, ключи в которой - имена
# (пути) кешируемых файлов, а ключи - время добавления и имя файла на
# диске.
class DiskCacher
  def initialize(path, max_items)
    @path = path
    @max_items = max_items

    # Индексный файл. Нужен чтобы не проебывать индекс кеша после рестарта.
    @index = YAML::Store.new(File.join(@path, 'index.dat'))
  end

  # Сохраняет файл в кеше.
  def store(name, content)
    fname = SecureRandom.hex
    File.write(File.join(@path, fname), content)

    @index.transaction do
      @index[:data] ||= {}
      @index[:data][name] = [Time.now.to_f, fname]

      if @index[:data].length > @max_items
        del_name, del_data = @index[:data].min_by { |k, v| v[0] }
        _, del_fname = del_data
        @index[:data].delete(del_name)
        full_path = File.join(@path, del_fname)
        File.delete(full_path) if File.exists?(full_path)
      end
    end
  end

  # Вытаскивает файл из кеша. Или возвращает nil.
  def load(name)
    content = nil
    @index.transaction do
      @index[:data] ||= {}
      data = @index[:data][name]
      if data
        _, fname = data
        full_path = File.join(@path, fname)
        content = File.read(full_path) if File.exists?(full_path)
      end
    end
    content
  end
end


# Бегает по FTP-серверу ЕИС, yield'ит зипы
class FtpRunner

  def initialize(params)
    @host = params[:host]
    @logpasses = params[:logpasses]
    @path = params[:path]
    @dates = params[:dates] or nil

    @files_cache = DiskCacher.new($config[:cache_path], $config[:cache_size])
  end

  def run
    Net::FTP.open(@host) do |ftp|
      ftp.passive = true
      login, password = get_logpass
      ftp.login(login, password)
      ftp.chdir(@path)
      all_files = get_dir_files(ftp, '.')
      all_files.each do |path, name|
        if not @dates or actual_zip_date?(name)
          full_path = "#{path}/#{name}"
          zip_content = get_binary_file(ftp, full_path)
          yield(full_path, zip_content)
        end
      end
    end
  end

  protected

  # Возвращает список файлов в директории и дочерних директориях
  # в формате [путь к файлу, имя файла].
  def get_dir_files(ftp, path)
    ftp.chdir(path)
    wd = ftp.pwd
    files = []
    ftp.nlst.each do |fname|
      if ftp_file?(ftp, fname)
        files << [wd, fname] if actual_zip_date?(fname)
      else
        files += get_dir_files(ftp, fname)
      end
    end
    ftp.chdir('..')
    files
  end

  # Проверяет по имени файла, подходит ли он под даты.
  # Файлы на ftp ООС в наименовании содержат две даты,
  # в формате YYYYMMDD**_YYYYMMDD**, цепляемся за них.
  def actual_zip_date?(zip_name)

    def dates_overlaps?(x, y)
      y[0] = Date.parse('0001-01-01') if y[0].nil?
      y[1] = Date.parse('2999-12-01') if y[1].nil?

      (x[0] - y[1]) * (y[0] - x[1]) >= 0
    end

    if zip_name =~ /(20\d{6})\d\d_(20\d{6})\d\d_\d+\.xml\.zip/
      file_from = Date.parse($1)
      file_to = Date.parse($2)
      dates_overlaps?([file_from, file_to], @dates)
    else
      false
    end
  end

  # Является ли файл на FTP файлом, а не директорией?
  def ftp_file?(ftp, file_name)
    ftp.chdir(file_name)
    ftp.chdir('..')
    false
  rescue
    true
  end

  # Определяет логин и пароль в зависимости от обрабатываемой директории
  def get_logpass
    @logpasses.each do |params|
      if @path =~ params[:prefix]
        return [params[:user], params[:pass]]
      end
    end
  end

  # Скачивает файл с FTP или получает из кэша.
  def get_binary_file(ftp, path)
    cache_file = @files_cache.load(path)
    if cache_file.nil?
      cache_file = ftp.getbinaryfile(path, nil)
      @files_cache.store(path, cache_file)
    end
    cache_file
  end
end


# Бегает по ZIP-файлам передаваемым FtpRunner'ом, распаковывает и
# yield'ит XML-файлы, содержащие искомые подстроки.
# В формате: имя zip-файла, имя xml-файла, содержимое xml-файла.
class XmlRunner

  def initialize(ftp_params, queries)
    @ftp_params = ftp_params
    @queries = queries
  end

  def run
    ftp_runner = FtpRunner.new(@ftp_params)
    ftp_runner.run do |zip_name, zip_data|
      Zip::File.open_buffer(zip_data) do |zf|
        zf.each do |xml|
          xml_data = xml.get_input_stream.read.force_encoding('UTF-8')
          if contains_queries?(xml_data)
            yield(zip_name, xml.name, xml_data)
          end
        end
      end
    end
  end

  protected

  # Содержит ли data искомые классом подстроки.
  def contains_queries?(data)
    upcase_content = data.upcase
    upcase_patterns = @queries.map(&:upcase)
    upcase_patterns.any? { |x| upcase_content.include?(x) }
  end
end


token_path =  File.join(File.dirname(__FILE__), '.token')
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
      $dialogs[message.chat.id] = dialog
      reply = dialog.receive(message.text)
      bot.api.send_message(chat_id: message.chat.id, text: reply)

    when '/about'
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "TODO"
      )

    else
      dialog = $dialogs[message.chat.id]
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

          $dialogs[message.chat.id] = nil

          # Начинаем обработку.
          runner = XmlRunner.new({
            host: $config[:host],
            logpasses: $config[:logpasses],
            pass: $config[:pass],
            path: data[:path_or_name],
            dates: data[:dates],
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
                  Faraday::UploadIO.new(StringIO.new(data), 'text/xml'),
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
