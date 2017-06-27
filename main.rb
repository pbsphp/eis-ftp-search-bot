#!/usr/bin/env ruby

require 'date'
require 'net/ftp'
require 'rubygems'
require 'zip'


# Бегает по FTP-серверу ЕИС, yield'ит зипы
class FtpRunner

  def initialize(params)
    @host = params[:host]
    @user = params[:user]
    @pass = params[:pass]
    @path = params[:path]
    @dates = params[:dates] or nil
  end

  def run
    Net::FTP.open(@host) do |ftp|
      ftp.passive = true
      ftp.login(@user, @pass)
      ftp.chdir(@path)
      all_files = get_dir_files(ftp, '.')
      all_files.each do |path, name|
        if not @dates or actual_zip_date?(name)
          full_path = "#{path}/#{name}"
          zip_content = ftp.getbinaryfile(full_path, nil)
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
      (x.begin - y.end) * (y.begin - x.end) >= 0
    end

    if zip_name =~ /(20\d{6})\d\d_(20\d{6})\d\d_\d+\.xml\.zip/
      file_from = Date.parse($1)
      file_to = Date.parse($2)
      dates_overlaps?(file_from..file_to, @dates)
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



runner = XmlRunner.new({
  host: 'ftp.zakupki.gov.ru',
  user: 'free',
  pass: 'free',
  path: '/fcs_regions/Tatarstan_Resp/purchaseplans/',
  dates: Date.parse('2017-06-01')..Date.parse('2018-01-01'),
}, [
  'customer'
])

runner.run do |zip_name, xml_name, data|
  puts zip_name
  puts "\t" + xml_name
  puts "\tBegins with: #{data[0..60].gsub('\n', '')}..."
end

