# Настройки по-умолчанию.
# Для изменения настроек необходимо скопировать и вставить этот файл
# как settings.rb в эту же директорию.


module Settings
  # Хост ftp.
  HOST = 'ftp.zakupki.gov.ru'

  # Для каждой директории свои логин/пароль.
  LOGPASSES = [{
    prefix: /^\/out\//, user: 'fz223free', pass: 'fz223free',
  }, {
    prefix: /.*/, user: 'free', pass: 'free',
  }]

  # Максимальное количество сообщений за один поиск. Чтобы не зафлудить.
  MAX_MESSAGES_LIMIT = 100

  # Путь к директории кеша.
  CACHE_PATH = '/tmp'
  # Размер кеша в файлах.
  CACHE_SIZE = 20
end
