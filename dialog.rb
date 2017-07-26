require 'date'


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

  # Все диалоги
  @@dialogs = []

  def self.dialogs
    @@dialogs
  end

  def self.dialogs=new_list
    @@dialogs = new_list
  end

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
    when /пз|планы?.?закупок/i
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
      ([\w\.\-]+)?  # первая дата
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
