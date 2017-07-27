require 'date'
require 'yaml/store'
require 'securerandom'


# Простой дисковый LRU кэш.
# Общий принцип действия: есть hash-таблица, ключи в которой - имена
# (пути) кешируемых файлов, а значения - время добавления и имя файла на
# диске.
class DiskCacher
  def initialize(path, max_items)
    @path = path
    @max_items = max_items

    # Индексный файл. Нужен чтобы не проебывать индекс кеша после рестарта.
    @index = YAML::Store.new(File.join(@path, 'pbs_disk_cacher_index.yaml'))
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
