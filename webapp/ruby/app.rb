# frozen_string_literal: true

require 'base64'
require 'bcrypt'
require 'digest'
require 'mysql2'
require 'mysql2-cs-bind'
require 'open3'
require 'securerandom'
require 'sinatra/base'
require 'sinatra/json'

require 'ddtrace/auto_instrument'

Datadog.configure do |c|
  c.tracing.instrument :sinatra, service_name: "freee.group:rocky-12-sinatra", analytics_enabled: true
  c.tracing.instrument :mysql2,  service_name: "freee.group:rocky-12-mysql2",  analytics_enabled: true
  c.env = 'prod'
  c.version = '1.3.0'
end

module Isupipe
  class App < Sinatra::Base
    enable :logging

    set :show_exceptions, :after_handler
    set :sessions, domain: 'u.isucon.dev', path: '/', expire_after: 1000*300
    set :session_secret, ENV.fetch('ISUCON13_SESSION_SECRETKEY', 'isucon13_session_cookiestore_defaultsecret').unpack('H*')[0]

    POWERDNS_SUBDOMAIN_ADDRESS = ENV.fetch('ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS')

    DEFAULT_SESSION_ID_KEY = 'SESSIONID'
    DEFAULT_SESSION_EXPIRES_KEY = 'EXPIRES'
    DEFAULT_USER_ID_KEY = 'USERID'
    DEFAULT_USERNAME_KEY = 'USERNAME'

    class HttpError < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        super(message || "HTTP error #{code}")
        @code = code
      end
    end

    error HttpError do
      e = env['sinatra.error']
      status e.code
      json(error: e.message)
    end

    helpers do
      def db_conn
        Thread.current[:db_conn] ||= connect_db
      end

      def connect_db
        Mysql2::Client.new(
          host: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_ADDRESS', '127.0.0.1'),
          port: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PORT', '3306').to_i,
          username: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_USER', 'isucon'),
          password: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PASSWORD', 'isucon'),
          database: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_DATABASE', 'isupipe'),
          symbolize_keys: true,
          cast_booleans: true,
          reconnect: true,
        )
      end

      def db_transaction(&block)
        db_conn.query('BEGIN')
        ok = false
        begin
          retval = block.call(db_conn)
          db_conn.query('COMMIT')
          ok = true
          retval
        ensure
          unless ok
            db_conn.query('ROLLBACK')
          end
        end
      end

      def decode_request_body(data_class)
        body = JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
        data_class.new(**data_class.members.map { |key| [key, body[key]] }.to_h)
      end

      def cast_as_integer(str)
        Integer(str, 10)
      rescue
        raise HttpError.new(400)
      end

      def verify_user_session!
        sess = session[DEFAULT_SESSION_ID_KEY]
        unless sess
          raise HttpError.new(403)
        end

        session_expires = sess[DEFAULT_SESSION_EXPIRES_KEY]
        unless session_expires
          raise HttpError.new(403)
        end

        now = Time.now
        if now.to_i > session_expires
          raise HttpError.new(401, 'session has expired')
        end

        nil
      end

      def fill_livestream_response(tx, livestream_model)
        owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livestream_model.fetch(:user_id)).first
        owner = fill_user_response(tx, owner_model)

        tags = tx.xquery('SELECT * FROM livestream_tags WHERE livestream_id = ?', livestream_model.fetch(:id)).map do |livestream_tag_model|
          tag_model = tx.xquery('SELECT * FROM tags WHERE id = ?', livestream_tag_model.fetch(:tag_id)).first
          {
            id: tag_model.fetch(:id),
            name: tag_model.fetch(:name),
          }
        end

        livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
          owner:,
          tags:,
        )
      end

      def fill_livecomment_response(tx, livecomment_model)
        comment_owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livecomment_model.fetch(:user_id)).first
        comment_owner = fill_user_response(tx, comment_owner_model)

        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livecomment_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        livecomment_model.slice(:id, :comment, :tip, :created_at).merge(
          user: comment_owner,
          livestream:,
        )
      end

      def fill_livecomment_report_response(tx, report_model)
        reporter_model = tx.xquery('SELECT * FROM users WHERE id = ?', report_model.fetch(:user_id)).first
        reporter = fill_user_response(tx, reporter_model)

        livecomment_model = tx.xquery('SELECT * FROM livecomments WHERE id = ?', report_model.fetch(:livecomment_id)).first
        livecomment = fill_livecomment_response(tx, livecomment_model)

        report_model.slice(:id, :created_at).merge(
          reporter:,
          livecomment:,
        )
      end

      def fill_reaction_response(tx, reaction_model)
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', reaction_model.fetch(:user_id)).first
        user = fill_user_response(tx, user_model)

        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', reaction_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        reaction_model.slice(:id, :emoji_name, :created_at).merge(
          user:,
          livestream:,
        )
      end

      def fill_user_response(tx, user_model)
        theme_model = tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_model.fetch(:id)).first

        icon_model = tx.xquery('SELECT image FROM icons WHERE user_id = ?', user_model.fetch(:id)).first
        image =
          if icon_model
            icon_model.fetch(:image)
          else
            File.binread(FALLBACK_IMAGE)
          end
        icon_hash = Digest::SHA256.hexdigest(image)

        {
          id: user_model.fetch(:id),
          name: user_model.fetch(:name),
          display_name: user_model.fetch(:display_name),
          description: user_model.fetch(:description),
          theme: {
            id: theme_model.fetch(:id),
            dark_mode: theme_model.fetch(:dark_mode),
          },
          icon_hash:,
        }
      end
      
      def fill_user_response2(tx, user_id, user_name, user_display_name, user_description)
        theme_model = tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_id).first

        icon_model = tx.xquery('SELECT image FROM icons WHERE user_id = ?', user_id).first
        image =
          if icon_model
            icon_model.fetch(:image)
          else
            File.binread(FALLBACK_IMAGE)
          end
        icon_hash = Digest::SHA256.hexdigest(image)

        {
          id: user_id,
          name: user_name,
          display_name: user_display_name,
          description: user_description,
          theme: {
            id: theme_model.fetch(:id),
            dark_mode: theme_model.fetch(:dark_mode),
          },
          icon_hash:,
        }
      end
    end

    # 初期化
    post '/api/initialize' do
      out, status = Open3.capture2e('../sql/init.sh')
      unless status.success?
        logger.warn("init.sh failed with out=#{out}")
        halt 500
      end

      json(
        language: 'ruby',
      )
    end

    # top
    get '/api/tag' do
      tag_models = db_transaction do |tx|
        tx.query('SELECT * FROM tags')
      end

      json(
        tags: tag_models.map { |tag_model|
          {
            id: tag_model.fetch(:id),
            name: tag_model.fetch(:name),
          }
        },
      )
    end

    # 配信者のテーマ取得API
    get '/api/user/:username/theme' do
      verify_user_session!

      username = params[:username]

      theme_model = db_transaction do |tx|
        user_model = tx.xquery('SELECT id FROM users WHERE name = ?', username).first
        unless user_model
          raise HttpError.new(404)
        end
        tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_model.fetch(:id)).first
      end

      json(
        id: theme_model.fetch(:id),
        dark_mode: theme_model.fetch(:dark_mode),
      )
    end

    # livestream

    ReserveLivestreamRequest = Data.define(
      :tags,
      :title,
      :description,
      :playlist_url,
      :thumbnail_url,
      :start_at,
      :end_at,
    )

    # reserve livestream
    post '/api/livestream/reservation' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      req = decode_request_body(ReserveLivestreamRequest)

      livestream = db_transaction do |tx|
        # 2023/11/25 10:00からの１年間の期間内であるかチェック
        term_start_at = Time.utc(2023, 11, 25, 1)
        term_end_at = Time.utc(2024, 11, 25, 1)
        reserve_start_at = Time.at(req.start_at, in: 'UTC')
        reserve_end_at = Time.at(req.end_at, in: 'UTC')
        if reserve_start_at >= term_end_at || reserve_end_at <= term_start_at
          raise HttpError.new(400, 'bad reservation time range')
        end

        start_id = (req.start_at - 1700874000) / 3600 + 1
        end_id = ((req.end_at - 1700874000) / 3600.0).ceil
        if (end_id - start_id) >=  0
        # 予約枠をみて、予約が可能か調べる
        # NOTE: 並列な予約のoverbooking防止にFOR UPDATEが必要
          tx.xquery('SELECT * FROM reservation_slots WHERE id BETWEEN ? AND ? FOR UPDATE', start_id, end_id).each do |slot|
            logger.info("#{slot.fetch(:start_at)} ~ #{slot.fetch(:end_at)}予約枠の残数 = #{slot.fetch(:slot)}")
            if slot.fetch(:slot) < 1
              raise HttpError.new(400, "予約期間 #{term_start_at.to_i} ~ #{term_end_at.to_i}に対して、予約区間 #{req.start_at} ~ #{req.end_at}が予約できません")
            end
          end
          tx.xquery('UPDATE reservation_slots SET slot = slot - 1 WHERE id BETWEEN ? AND ?', start_id, end_id)
        end 

        tx.xquery('INSERT INTO livestreams (user_id, title, description, playlist_url, thumbnail_url, start_at, end_at) VALUES(?, ?, ?, ?, ?, ?, ?)', user_id, req.title, req.description, req.playlist_url, req.thumbnail_url, req.start_at, req.end_at)
        livestream_id = tx.last_id

	# タグ追加
        req.tags.each do |tag_id|
          tx.xquery('INSERT INTO livestream_tags (livestream_id, tag_id) VALUES (?, ?)', livestream_id, tag_id)
        end

        fill_livestream_response(tx, {
          id: livestream_id,
          user_id:,
          title: req.title,
          description: req.description,
          playlist_url: req.playlist_url,
          thumbnail_url: req.thumbnail_url,
          start_at: req.start_at,
          end_at: req.end_at,
        })
      end

      status 201
      json(livestream)
    end

    # list livestream
    get '/api/livestream/search' do
      key_tag_name = params[:tag] || ''

      livestreams = db_transaction do |tx|
        livestream_models =
          if key_tag_name != ''
            # タグによる取得
            tag_id_list = tx.xquery('SELECT id FROM tags WHERE name = ?', key_tag_name, as: :array).map(&:first)
            tx.xquery('SELECT * FROM livestream_tags WHERE tag_id IN (?) ORDER BY livestream_id DESC', tag_id_list).map do |key_tagged_livestream|
              tx.xquery('SELECT * FROM livestreams WHERE id = ?', key_tagged_livestream.fetch(:livestream_id)).first
            end
          else
            # 検索条件なし
            query = 'SELECT * FROM livestreams ORDER BY id DESC'
            limit_str = params[:limit] || ''
            if limit_str != ''
              limit = cast_as_integer(limit_str)
              query = "#{query} LIMIT #{limit}"
            end

            tx.xquery(query).to_a
          end

        fill_livestreams_response(tx, livestream_models)
        # livestream_models.map do |livestream_model|
        #   fill_livestream_response(tx, livestream_model)
        # end
      end

      json(livestreams)
    end

    def fill_livestreams_response(tx, livestream_models)
      user_ids = livestream_models.map { |model| model.fetch(:user_id) }

      # 関連するすべてのユーザー情報を一度のクエリで取得
      owners = tx.xquery('SELECT * FROM users WHERE id IN (?)', user_ids).to_a
  
      owners_model = fill_users_response(tx, owners)

      livestream_ids = livestream_models.map { |model| model.fetch(:id) }

      # 関連するすべてのタグを一度のクエリで取得
      tags_data = 
        tx.xquery(<<~SQL, livestream_ids).to_a
          SELECT lt.livestream_id, t.id, t.name
          FROM livestream_tags lt
          INNER JOIN tags t ON lt.tag_id = t.id
          WHERE lt.livestream_id IN (?)
        SQL

      # livestream_id をキーとするタグのハッシュを作成
      tags_hash = tags_data.each_with_object({}) do |tag_data, hash|
        livestream_id = tag_data[:livestream_id]
        hash[livestream_id] ||= []
        hash[livestream_id] << { id: tag_data[:id], name: tag_data[:name] }
      end

      processed_livestreams = livestream_models.map do |livestream_model|
        livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
          owner: owners_model[livestream_model[:user_id]],
          tags: tags_hash[livestream_model[:id]] || []
        )
      end
    end

    def fill_users_response(tx, user_models)
      user_ids = user_models.map { |model| model.fetch(:id) }

      # 関連するすべてのテーマを一度のクエリで取得
      themes = tx.xquery('SELECT * FROM themes WHERE user_id IN (?)', user_ids).to_a

      # 関連するすべてのアイコンを一度のクエリで取得
      icons = tx.xquery('SELECT * FROM icons WHERE user_id IN (?)', user_ids).to_a
      icons_hash = icons.each_with_object({}) do |icon, hash|
        hash[icon[:user_id]] = icon
      end

      # user_id をキーとするテーマとアイコンのハッシュを作成
      themes_hash = themes.each_with_object({}) { |theme, hash| hash[theme[:user_id]] = theme }

      icons_hash_2 = user_models.each_with_object({}) do |user, hash|
        image =
        if icons_hash[user[:id]]
          icon.fetch(:image)
        else
          File.binread(FALLBACK_IMAGE)
        end
        icon_image = Digest::SHA256.hexdigest(image)
        hash[user[:id]] = icon_image
      end

      user_models.each_with_object({}) do |user, hash|
        hash[user.fetch(:id)] = {
        id: user.fetch(:id),
        name: user.fetch(:name),
        display_name: user.fetch(:display_name),
        description: user.fetch(:description),
        theme: {
          id: themes_hash[user[:id]].fetch(:id),
          dark_mode: themes_hash[user[:id]].fetch(:dark_mode),
        },
        icon_hash: icons_hash_2[user[:id]],
        }
      end
    end

    get '/api/livestream' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestreams = db_transaction do |tx|
        tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user_id).map do |livestream_model|
          fill_livestream_response(tx, livestream_model)
        end
      end

      json(livestreams)
    end

    get '/api/user/:username/livestream' do
      verify_user_session!
      username = params[:username]

      livestreams = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(404, 'user not found')
        end

        tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id)).map do |livestream_model|
          fill_livestream_response(tx, livestream_model)
        end
      end

      json(livestreams)
    end

    # ユーザ視聴開始 (viewer)
    post '/api/livestream/:livestream_id/enter' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      db_transaction do |tx|
        created_at = Time.now.to_i
        tx.xquery('INSERT INTO livestream_viewers_history (user_id, livestream_id, created_at) VALUES(?, ?, ?)', user_id, livestream_id, created_at)
      end

      ''
    end

    # ユーザ視聴終了 (viewer)
    delete '/api/livestream/:livestream_id/exit' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      db_transaction do |tx|
        tx.xquery('DELETE FROM livestream_viewers_history WHERE user_id = ? AND livestream_id = ?', user_id, livestream_id)
      end

      ''
    end

    # get livestream
    get '/api/livestream/:livestream_id' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      livestream = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404)
        end

        fill_livestream_response(tx, livestream_model)
      end

      json(livestream)
    end

    # (配信者向け)ライブコメントの報告一覧取得API
    get '/api/livestream/:livestream_id/report' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      reports = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        if livestream_model.fetch(:user_id) != user_id
          raise HttpError.new(403, "can't get other streamer's livecomment reports")
        end

        tx.xquery('SELECT * FROM livecomment_reports WHERE livestream_id = ?', livestream_id).map do |report_model|
          fill_livecomment_report_response(tx, report_model)
        end
      end

      json(reports)
    end

    # get polling livecomment timeline
    get '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      livecomments = db_transaction do |tx|
        query = '
        SELECT 
          livecomments.*, 
          livestreams.id AS livestream_id,
          livestreams.title AS livestream_title,
          livestreams.description AS livestream_description,
          livestreams.playlist_url AS livestream_playlist_url,
          livestreams.thumbnail_url AS livestream_thumbnail_url,
          livestreams.start_at AS livestream_start_at,
          livestreams.end_at AS livestream_end_at,
          users.id AS user_id, 
          users.name AS user_name, 
          users.display_name AS user_display_name, 
          users.description AS user_description, 
          themes.id AS theme_id, 
          themes.dark_mode AS theme_dark_mode, 
          icons.image AS image
        FROM livecomments 
        INNER JOIN users ON livecomments.user_id = users.id
        INNER JOIN themes ON users.id = themes.user_id
        INNER JOIN livestreams ON livecomments.livestream_id = livestreams.id
        LEFT OUTER JOIN icons ON users.id = icons.user_id
        WHERE livecomments.livestream_id = ? 
        ORDER BY created_at DESC'
        limit_str = params[:limit] || ''
        if limit_str != ''
          limit = cast_as_integer(limit_str)
          query = "#{query} LIMIT #{limit}"
        end

        query_result = tx.xquery(query, livestream_id)

        livestream_ids = query_result.map { |livecomment_model| livecomment_model.fetch(:livestream_id) }.uniq

        tags_array = {}
        tag_query = "SELECT tags.id AS id, tags.name AS name, livestream_tags.livestream_id AS livestream_id
          FROM tags 
          INNER JOIN livestream_tags ON tags.id = livestream_tags.tag_id 
          WHERE livestream_tags.livestream_id IN (#{ livestream_ids.map { |_row| '?' }.join(',') })"

        if !livestream_ids.empty?
          tx.xquery(tag_query, livestream_ids).map do |tag_model|
            tags_array[tag_model.fetch(:livestream_id)] ||= []
            tags_array[tag_model.fetch(:livestream_id)] << {
              id: tag_model.fetch(:id),
              name: tag_model.fetch(:name),
            }
          end
        end

        query_result.map do |livecomment_model|
          image =
            if livecomment_model.fetch(:image)
              livecomment_model.fetch(:image)
            else
              File.binread(FALLBACK_IMAGE)
            end
          icon_hash = Digest::SHA256.hexdigest(image)

          comment_owner = {
            id: livecomment_model.fetch(:user_id),
            name: livecomment_model.fetch(:user_name),
            display_name: livecomment_model.fetch(:user_display_name),
            description: livecomment_model.fetch(:user_description),
            theme: {
              id: livecomment_model.fetch(:theme_id),
              dark_mode: livecomment_model.fetch(:theme_dark_mode),
            },
            icon_hash:,
          }

          #livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livecomment_model.fetch(:livestream_id)).first
          #livestream = fill_livestream_response(tx, livestream_model)


          #owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livestream_model.fetch(:user_id)).first
          #owner = fill_user_response(tx, owner_model)

          # tags = tx.xquery('SELECT * FROM livestream_tags WHERE livestream_id = ?', livecomment_model.fetch(:livestream_id)).map do |livestream_tag_model|
          #   tag_model = tx.xquery('SELECT * FROM tags WHERE id = ?', livestream_tag_model.fetch(:tag_id)).first
          #   {
          #     id: tag_model.fetch(:id),
          #     name: tag_model.fetch(:name),
          #   }
          # end

          # livestream = livecomment_model.slice(:livestream_id, :livestream_title, :livestream_description, :livestream_playlist_url, :livestream_thumbnail_url, :livestream_start_at, :livestream_end_at).merge(
          #   owner: comment_owner,
          #   tags:,
          # )

          livecomment_model.slice(:id, :comment, :tip, :created_at).merge(
            user: comment_owner,
            livestream: {
              id: livecomment_model.fetch(:livestream_id),
              title: livecomment_model.fetch(:livestream_title),
              description: livecomment_model.fetch(:livestream_description),
              playlist_url: livecomment_model.fetch(:livestream_playlist_url),
              thumbnail_url: livecomment_model.fetch(:livestream_thumbnail_url),
              start_at: livecomment_model.fetch(:livestream_start_at),
              end_at: livecomment_model.fetch(:livestream_end_at),
              owner: comment_owner,
              tags: tags_array[livecomment_model.fetch(:livestream_id)] || [],
            },
          )
        end
      end

      json(livecomments)
    end

    get '/api/livestream/:livestream_id/ngwords' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      ng_words = db_transaction do |tx|
        tx.xquery('SELECT * FROM ng_words WHERE user_id = ? AND livestream_id = ? ORDER BY created_at DESC', user_id, livestream_id).to_a
      end

      json(ng_words)
    end

    PostLivecommentRequest = Data.define(
      :comment,
      :tip,
    )

    # ライブコメント投稿
    post '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(PostLivecommentRequest)

      livecomment = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        # スパム判定
        tx.xquery('SELECT id, user_id, livestream_id, word FROM ng_words WHERE user_id = ? AND livestream_id = ?', livestream_model.fetch(:user_id), livestream_model.fetch(:id)).each do |ng_word|
          query = <<~SQL
            SELECT COUNT(*)
            FROM
            (SELECT ? AS text) AS texts
            INNER JOIN
            (SELECT CONCAT('%', ?, '%')	AS pattern) AS patterns
            ON texts.text LIKE patterns.pattern
          SQL
          hit_spam = tx.xquery(query, req.comment, ng_word.fetch(:word), as: :array).first[0]
          logger.info("[hit_spam=#{hit_spam}] comment = #{req.comment}")
          if hit_spam >= 1
            raise HttpError.new(400, 'このコメントがスパム判定されました')
          end
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomments (user_id, livestream_id, comment, tip, created_at) VALUES (?, ?, ?, ?, ?)', user_id, livestream_id, req.comment, req.tip, now)
        livecomment_id = tx.last_id

        fill_livecomment_response(tx, {
          id: livecomment_id,
          user_id:,
          livestream_id:,
          comment: req.comment,
          tip: req.tip,
          created_at: now,
        })
      end

      status 201
      json(livecomment)
    end

    # ライブコメント報告
    post '/api/livestream/:livestream_id/livecomment/:livecomment_id/report' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])
      livecomment_id = cast_as_integer(params[:livecomment_id])

      report = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        livecomment_model = tx.xquery('SELECT * FROM livecomments WHERE id = ?', livecomment_id).first
        unless livecomment_model
          raise HttpError.new(404, 'livecomment not found')
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomment_reports(user_id, livestream_id, livecomment_id, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, livecomment_id, now)
        report_id = tx.last_id

        fill_livecomment_report_response(tx, {
          id: report_id,
          user_id:,
          livestream_id:,
          livecomment_id:,
          created_at: now,
        })
      end

      status 201
      json(report)
    end

    ModerateRequest = Data.define(:ng_word)

    # 配信者によるモデレーション (NGワード登録)
    post '/api/livestream/:livestream_id/moderate' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(ModerateRequest)

      word_id = db_transaction do |tx|
        # 配信者自身の配信に対するmoderateなのかを検証
        owned_livestreams = tx.xquery('SELECT * FROM livestreams WHERE id = ? AND user_id = ?', livestream_id, user_id).to_a
        if owned_livestreams.empty?
          raise HttpError.new(400, "A streamer can't moderate livestreams that other streamers own")
        end

        tx.xquery('INSERT INTO ng_words(user_id, livestream_id, word, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.ng_word, Time.now.to_i)
        word_id = tx.last_id

        query = <<~SQL
          DELETE FROM livecomments
          WHERE
          livestream_id = ? AND
          (SELECT COUNT(*)
          FROM
          (SELECT comment AS text) AS texts
          INNER JOIN
          (SELECT CONCAT('%', ?, '%') AS pattern) AS patterns
          ON texts.text LIKE patterns.pattern) >= 1
        SQL
       
        tx.xquery(query, livestream_id, req.ng_word)

        word_id
      end

      status 201
      json(word_id:)
    end

    get '/api/livestream/:livestream_id/reaction' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      reactions = db_transaction do |tx|
        query = '
          SELECT 
            reactions.*, 
            livestreams.id AS livestream_id,
            livestreams.title AS livestream_title,
            livestreams.description AS livestream_description,
            livestreams.playlist_url AS livestream_playlist_url,
            livestreams.thumbnail_url AS livestream_thumbnail_url,
            livestreams.start_at AS livestream_start_at,
            livestreams.end_at AS livestream_end_at,
            users.id AS user_id, 
            users.name AS user_name, 
            users.display_name AS user_display_name, 
            users.description AS user_description, 
            themes.id AS theme_id, 
            themes.dark_mode AS theme_dark_mode, 
            icons.image AS icon_image
          FROM reactions 
          INNER JOIN users ON reactions.user_id = users.id
          INNER JOIN themes ON users.id = themes.user_id
          INNER JOIN livestreams ON reactions.livestream_id = livestreams.id
          LEFT OUTER JOIN icons ON users.id = icons.user_id
          WHERE reactions.livestream_id = ?
          ORDER BY created_at DESC
        '
        limit_str = params[:limit] || ''
        if limit_str != ''
          limit = cast_as_integer(limit_str)
          query = "#{query} LIMIT #{limit}"
        end

        query_result = tx.xquery(query, livestream_id)

        livestream_ids = query_result.map { |livecomment_model| livecomment_model.fetch(:livestream_id) }.uniq
        tags_array = {}
        if !livestream_ids.empty?
          tx.xquery("
            SELECT tags.id AS id, tags.name AS name, livestream_tags.livestream_id AS livestream_id
            FROM tags 
            INNER JOIN livestream_tags ON tags.id = livestream_tags.tag_id 
            WHERE livestream_tags.livestream_id IN (#{ livestream_ids.map { |_row| '?' }.join(',') })", 
          *livestream_ids).map do |tag_model|
            tags_array[tag_model.fetch(:livestream_id)] ||= []
            tags_array[tag_model.fetch(:livestream_id)] << {
              id: tag_model.fetch(:id),
              name: tag_model.fetch(:name),
            }
          end
        end

        query_result.map do |reaction_model|
          #user_model = tx.xquery('SELECT * FROM users WHERE id = ?', reaction_model.fetch(:user_id)).first
          #user = fill_user_response(tx, user_model)

          #theme_model = tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_model.fetch(:id)).first

          # icon_model = tx.xquery('SELECT image FROM icons WHERE user_id = ?', user_model.fetch(:id)).first
          image =
            if reaction_model.fetch(:icon_image)
              reaction_model.fetch(:icon_image)
            else
              File.binread(FALLBACK_IMAGE)
            end
          icon_hash = Digest::SHA256.hexdigest(image)

          user = {
            id: reaction_model.fetch(:user_id),
            name: reaction_model.fetch(:user_name),
            display_name: reaction_model.fetch(:user_display_name),
            description: reaction_model.fetch(:user_description),
            theme: {
              id: reaction_model.fetch(:theme_id),
              dark_mode: reaction_model.fetch(:theme_dark_mode),
            },
            icon_hash:,
          }

          #livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', reaction_model.fetch(:livestream_id)).first
          #livestream = fill_livestream_response(tx, livestream_model)

          # owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livestream_model.fetch(:user_id)).first
          # owner = fill_user_response(tx, owner_model)

          # tags = tx.xquery('SELECT * FROM livestream_tags WHERE livestream_id = ?', livestream_model.fetch(:id)).map do |livestream_tag_model|
          #   tag_model = tx.xquery('SELECT * FROM tags WHERE id = ?', livestream_tag_model.fetch(:tag_id)).first
          #   {
          #     id: tag_model.fetch(:id),
          #     name: tag_model.fetch(:name),
          #   }
          # end

          # livestream = livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
          #   owner: user,
          #   tags:,
          # )

          reaction_model.slice(:id, :emoji_name, :created_at).merge(
            user:,
            livestream: {
              id: reaction_model.fetch(:livestream_id),
              title: reaction_model.fetch(:livestream_title),
              description: reaction_model.fetch(:livestream_description),
              playlist_url: reaction_model.fetch(:livestream_playlist_url),
              thumbnail_url: reaction_model.fetch(:livestream_thumbnail_url),
              start_at: reaction_model.fetch(:livestream_start_at),
              end_at: reaction_model.fetch(:livestream_end_at),
              owner: user,
              tags: tags_array[reaction_model.fetch(:livestream_id)] || [],
            },
          )
        end
      end

      json(reactions)
    end

    PostReactionRequest = Data.define(:emoji_name)

    post '/api/livestream/:livestream_id/reaction' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = Integer(params[:livestream_id], 10)

      req = decode_request_body(PostReactionRequest)

      reaction = db_transaction do |tx|
        created_at = Time.now.to_i
        tx.xquery('INSERT INTO reactions (user_id, livestream_id, emoji_name, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.emoji_name, created_at)
        reaction_id = tx.last_id

        fill_reaction_response(tx, {
          id: reaction_id,
          user_id:,
          livestream_id:,
          emoji_name: req.emoji_name,
          created_at:,
        })
      end

      status 201
      json(reaction)
    end

    BCRYPT_DEFAULT_COST = 4
    FALLBACK_IMAGE = '../img/NoImage.jpg'

    get '/api/user/:username/icon' do
      username = params[:username]

      image = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(404, 'not found user that has the given username')
        end
        tx.xquery('SELECT image FROM icons WHERE user_id = ?', user.fetch(:id)).first
      end

      content_type 'image/jpeg'
      if image
        image[:image]
      else
        send_file FALLBACK_IMAGE
      end
    end

    PostIconRequest = Data.define(:image)

    post '/api/icon' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      req = decode_request_body(PostIconRequest)
      image = Base64.decode64(req.image)

      icon_id = db_transaction do |tx|
        tx.xquery('DELETE FROM icons WHERE user_id = ?', user_id)
        tx.xquery('INSERT INTO icons (user_id, image) VALUES (?, ?)', user_id, image)
        tx.last_id
      end

      status 201
      json(
        id: icon_id,
      )
    end

    get '/api/user/me' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', user_id).first
        unless user_model
          raise HttpError.new(404)
        end
        fill_user_response(tx, user_model)
      end

      json(user)
    end

    PostUserRequest = Data.define(
      :name,
      :display_name,
      :description,
      # password is non-hashed password.
      :password,
      :theme,
    )

    # ユーザ登録API
    post '/api/register' do
      req = decode_request_body(PostUserRequest)
      if req.name == 'pipe'
        raise HttpError.new(400, "the username 'pipe' is reserved")
      end

      hashed_password = BCrypt::Password.create(req.password, cost: BCRYPT_DEFAULT_COST)

      user = db_transaction do |tx|
        tx.xquery('INSERT INTO users (name, display_name, description, password) VALUES(?, ?, ?, ?)', req.name, req.display_name, req.description, hashed_password)
        user_id = tx.last_id

        tx.xquery('INSERT INTO themes (user_id, dark_mode) VALUES(?, ?)', user_id, req.theme.fetch(:dark_mode))

        out, status = Open3.capture2e('pdnsutil', 'add-record', 'u.isucon.dev', req.name, 'A', '0', POWERDNS_SUBDOMAIN_ADDRESS)
        unless status.success?
          raise HttpError.new(500, "pdnsutil failed with out=#{out}")
        end

        fill_user_response(tx, {
          id: user_id,
          name: req.name,
          display_name: req.display_name,
          description: req.description,
        })
      end

      status 201
      json(user)
    end

    LoginRequest = Data.define(
      :username,
      # password is non-hashed password.
      :password,
    )

    # ユーザログインAPI
    post '/api/login' do
      req = decode_request_body(LoginRequest)

      user_model = db_transaction do |tx|
        # usernameはUNIQUEなので、whereで一意に特定できる
        tx.xquery('SELECT * FROM users WHERE name = ?', req.username).first.tap do |user_model|
          unless user_model
            raise HttpError.new(401, 'invalid username or password')
          end
        end
      end

      unless BCrypt::Password.new(user_model.fetch(:password)).is_password?(req.password)
        raise HttpError.new(401, 'invalid username or password')
      end

      session_end_at = Time.now + 10*60*60
      session_id = SecureRandom.uuid
      session[DEFAULT_SESSION_ID_KEY] = {
        DEFAULT_SESSION_ID_KEY => session_id,
        DEFAULT_USER_ID_KEY => user_model.fetch(:id),
        DEFAULT_USERNAME_KEY => user_model.fetch(:name),
        DEFAULT_SESSION_EXPIRES_KEY => session_end_at.to_i,
      }

      ''
    end

    # ユーザ詳細API
    get '/api/user/:username' do
      verify_user_session!

      username = params[:username]

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user_model
          raise HttpError.new(404)
        end

        fill_user_response(tx, user_model)
      end

      json(user)
    end

    UserRankingEntry = Data.define(:username, :score)

    get '/api/user/:username/statistics' do
      verify_user_session!

      username = params[:username]

      # ユーザごとに、紐づく配信について、累計リアクション数、累計ライブコメント数、累計売上金額を算出
      # また、現在の合計視聴者数もだす

      stats = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(400)
        end

        # ランク算出
        users = tx.xquery('SELECT * FROM users').to_a

        reactions = tx.xquery(<<~SQL).to_a
          SELECT u.id, COUNT(r.id) AS reaction_count FROM users u
          LEFT JOIN livestreams l ON l.user_id = u.id
          LEFT JOIN reactions r ON r.livestream_id = l.id
          GROUP BY u.id
        SQL

        tips = tx.xquery(<<~SQL).to_a
          SELECT u.id, IFNULL(SUM(l2.tip), 0) AS tip_sum FROM users u
          LEFT JOIN livestreams l ON l.user_id = u.id
          LEFT JOIN livecomments l2 ON l2.livestream_id = l.id
          GROUP BY u.id
        SQL

        reactions_hash = reactions.each_with_object({}) do |reaction, hash|
          hash[reaction[:id]] = reaction[:reaction_count]
        end

        tips_hash = tips.each_with_object({}) do |tip, hash|
          hash[tip[:id]] = tip[:tip_sum]
        end

        ranking = users.map do |user|
          score = reactions_hash[user.fetch(:id)] + tips_hash[user.fetch(:id)]
          UserRankingEntry.new(username: user.fetch(:name), score:)
        end

        ranking.sort_by! { |entry| [entry.score, entry.username] }
        ridx = ranking.rindex { |entry| entry.username == username }
        rank = ranking.size - ridx

        # リアクション数
        total_reactions = tx.xquery(<<~SQL, username, as: :array).first[0]
          SELECT COUNT(*) FROM users u
          INNER JOIN livestreams l ON l.user_id = u.id
          INNER JOIN reactions r ON r.livestream_id = l.id
          WHERE u.name = ?
        SQL

        # ライブコメント数、チップ合計
        total_livecomments = 0
        total_tip = 0
        livestreams = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id))
        livestreams.each do |livestream|
          tx.xquery('SELECT * FROM livecomments WHERE livestream_id = ?', livestream.fetch(:id)).each do |livecomment|
            total_tip += livecomment.fetch(:tip)
            total_livecomments += 1
          end
        end

        # 合計視聴者数
        viewers_count = 0
        livestreams.each do |livestream|
          cnt = tx.xquery('SELECT COUNT(*) FROM livestream_viewers_history WHERE livestream_id = ?', livestream.fetch(:id), as: :array).first[0]
          viewers_count += cnt
        end

        # お気に入り絵文字
        favorite_emoji = tx.xquery(<<~SQL, username).first&.fetch(:emoji_name)
          SELECT r.emoji_name
          FROM users u
          INNER JOIN livestreams l ON l.user_id = u.id
          INNER JOIN reactions r ON r.livestream_id = l.id
          WHERE u.name = ?
          GROUP BY emoji_name
          ORDER BY COUNT(*) DESC, emoji_name DESC
          LIMIT 1
        SQL

        {
          rank:,
          viewers_count:,
          total_reactions:,
          total_livecomments:,
          total_tip:,
          favorite_emoji:,
        }
      end

      json(stats)
    end

    LivestreamRankingEntry = Data.define(:livestream_id, :score)

    # ライブ配信統計情報
    get '/api/livestream/:livestream_id/statistics' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      stats = db_transaction do |tx|
        unless tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
          raise HttpError.new(400)
        end

        # ランク算出
        ranking = tx.xquery('SELECT * FROM livestreams').map do |livestream|
          reactions = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN reactions r ON l.id = r.livestream_id WHERE l.id = ?', livestream.fetch(:id), as: :array).first[0]

          total_tips = tx.xquery('SELECT IFNULL(SUM(l2.tip), 0) FROM livestreams l INNER JOIN livecomments l2 ON l.id = l2.livestream_id WHERE l.id = ?', livestream.fetch(:id), as: :array).first[0]

          score = reactions + total_tips
          LivestreamRankingEntry.new(livestream_id: livestream.fetch(:id), score:)
        end
        ranking.sort_by! { |entry| [entry.score, entry.livestream_id] }
        ridx = ranking.rindex { |entry| entry.livestream_id == livestream_id }
        rank = ranking.size - ridx

	# 視聴者数算出
        viewers_count = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livestream_viewers_history h ON h.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

	# 最大チップ額
        max_tip = tx.xquery('SELECT IFNULL(MAX(tip), 0) FROM livestreams l INNER JOIN livecomments l2 ON l2.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

	# リアクション数
        total_reactions = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN reactions r ON r.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

	# スパム報告数
        total_reports = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livecomment_reports r ON r.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        {
          rank:,
          viewers_count:,
          max_tip:,
          total_reactions:,
          total_reports:,
        }
      end

      json(stats)
    end

    get '/api/payment' do
      total_tip = db_transaction do |tx|
        tx.xquery('SELECT IFNULL(SUM(tip), 0) FROM livecomments', as: :array).first[0]
      end

      json(total_tip:)
    end
  end
end
