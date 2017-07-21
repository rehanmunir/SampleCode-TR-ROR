class Hotelmanager::HotelReservationsController < Hotelmanager::HotelmanagerController

  before_action{ add_breadcrumb t('global.reservations'), event_venues_hotelmanager_hotel_reservations_path }
  before_action { @hotels_missing_view_reservation_privileges = (current_user.managing_hotels - which_hotels_allowed_to_view_reservations_query) }
  decorates_assigned :orders, :order, :hotel

  def update
    rows_updated = 0
    hotel_reservation_code = params[:hotel_reservation_code]
    hotel_reservations = selected_reservations_query
    HotelReservation.transaction do
      rows_updated = hotel_reservations.update_all(hotel_reservation_code: hotel_reservation_code)
    end
    if rows_updated > 0
      IndividualMailer.delay.hotel_reservation_code(hotel_reservation_code)
      head 204
    else
      render plain: '', status: 400
    end
  end

  def event_venues
    @hotel_room_list_by_event_venue_all=hotel_reservations_query.group(:event_venue).count("distinct(order_id)")
    @hotel_room_list_by_event_venue_processing=hotel_reservations_query.for_quick_cancellation_period(true).group("hotel_reservations.event_venue_id").count("distinct(order_id)")
    @hotel_room_list_by_event_venue_without_code=hotel_reservations_query.without_hotel_code_after_cancellation_period.group("hotel_reservations.event_venue_id").count("distinct(order_id)")

    hotel_ids = hotels_with_view_access.pluck(:id).join(',')
    @people_count_by_event_venue =
        if hotel_ids.present?
          sql = " select event_venue_id, sum(people_count_sum) from (SELECT event_venue_id, sum(people_count)/count(people_count) as people_count_sum FROM hotel_reservations INNER JOIN orders ON orders.id = hotel_reservations.order_id WHERE (hotel_reservations.order_id IS NOT NULL AND orders.placed_at IS NOT NULL) AND hotel_reservations.hotel_id IN (SELECT hotels.id FROM hotels INNER JOIN hotels_hotel_managers ON hotels.id = hotels_hotel_managers.hotel_id WHERE (hotels.deleted=false) AND hotels_hotel_managers.user_id = #{current_user.id} AND hotels.id IN (#{hotel_ids})) GROUP BY event_venue_id, order_id) t group by event_venue_id "
          @people_count_by_event_venue = Hash[ActiveRecord::Base.connection.select_all(sql).map{|x| [x['event_venue_id'].to_i, x['sum'].to_i] }]
        else
          {}
        end
  end

  def teams
    teams_breadcrumb
    @teams_all = hotel_reservations_query.for_event_venue(@event_venue).group('hotel_reservations.team_id').count("distinct(order_id)")
    @teams_processing = hotel_reservations_query.for_event_venue(@event_venue).for_quick_cancellation_period(true).group("team_id").count("distinct(order_id)")
    @teams_without_code = hotel_reservations_query.for_event_venue(@event_venue).without_hotel_code_after_cancellation_period.group("team_id").count("distinct(order_id)")

    hotel_ids = hotels_with_view_access.pluck(:id).join(',')
    raise404 unless hotel_ids.present?

    sql = " select team_id, sum(people_count_sum) from (SELECT team_id, sum(people_count)/count(people_count) as people_count_sum FROM hotel_reservations INNER JOIN orders ON orders.id = hotel_reservations.order_id WHERE (hotel_reservations.order_id IS NOT NULL AND orders.placed_at IS NOT NULL) AND hotel_reservations.hotel_id IN (SELECT hotels.id FROM hotels INNER JOIN hotels_hotel_managers ON hotels.id = hotels_hotel_managers.hotel_id WHERE (hotels.deleted=false) AND hotels_hotel_managers.user_id = #{current_user.id} AND event_venue_id = #{@event_venue.id} AND hotels.id IN (#{hotel_ids})) GROUP BY team_id, order_id) t group by team_id "
    @people_count_by_team = Hash[ActiveRecord::Base.connection.select_all(sql).map{|x| [x['team_id'].to_i, x['sum'].to_i] }]
  end

  def team
    team_breadcrumb
    @hotel_reservations_by_order = hotel_reservations_query.for_event_venue(@event_venue).for_team(@team).includes(:order, {hotel: :address}, {hotel_quote_rate: [:hotel_quote_qtys, :hotel_quote_rate_group]}).group_by(&:order)
  end

  def credit_card
    set_cache_buster_headers
    if current_user.reauthorized_at_recently(request)
      query = HotelReservation.for_hotel(hotels_with_view_access).complete
      @credit_card = find_credit_card(query)
      head :not_found unless @credit_card
    else
      head :forbidden
    end
  end

  def edit_order
    team_breadcrumb
    @hotel_reservations = selected_reservations_query
    @hotel = @hotel_reservations.first.hotel
  end

  def update_order
    team_breadcrumb  # loads event and team
    @hotel_reservations = selected_reservations_query
    @order.with_lock do
      @order.set_quick_cancellation_expire_at!(5)
      @hotel_reservations.each do |hotel_reservation|
        desired = params["hotel_reservation_#{hotel_reservation.id}"].to_i rescue nil
        next unless desired
        order_line_item = OrderLineItem.for_orderable(hotel_reservation).first
        next unless order_line_item
        if desired < order_line_item.qty
          @order.update_order_line_item(order_line_item.id, desired)
        end
      end
      @order.set_quick_cancellation_expire_at!(-5)
      flash[:notice] = t('global.reservations_cancelled')
    end
    redirect_to team_hotelmanager_hotel_reservations_path(@event_venue, @team)
  end

  private

  def teams_breadcrumb
    add_breadcrumb t('global.events'), event_venues_hotelmanager_hotel_reservations_path
    @event_venue = EventVenue.find(params[:event_venue_id])
  end

  def team_breadcrumb
    teams_breadcrumb

    @team = Team.find(params[:team_id])
    add_breadcrumb t('global.teams'), teams_hotelmanager_hotel_reservations_path(@event_venue)
    add_breadcrumb @team.name, team_hotelmanager_hotel_reservations_path(@event_venue, @team)
  end

  def hotel_reservations_query(order_id=nil)
    ret = HotelReservation.complete.includes(order: :credit_card).for_hotel(hotels_with_view_access)
    if order_id
      ret.where(:order_id, order_id)
    end
    return ret
  end

  def hotels_with_view_access
    current_user.managing_hotels.where(id: which_hotels_allowed_to_view_reservations_query.to_a)
  end

  def selected_reservations_query
    order_id = params[:id]
    query = HotelReservation.for_hotel(hotels_with_view_access)
    @order = Order.complete.joins("INNER JOIN hotel_reservations ON hotel_reservations.order_id = orders.id").merge(query).find(order_id) || raise404
    query = query.for_order(order_id)
    return query
  end

  def which_hotels_allowed_to_view_reservations_query
    Hotel.where(id: PrivilegeUtil.to_object_ids(current_user, Privilege::HOTEL_MANAGER_VIEW_RESERVATIONS, Hotel))
  end

  def find_credit_card(base_query)
    card_ids = base_query.for_credit_card(params[:credit_card_id]).pluck("credit_cards.id")
    return nil if card_ids.blank?
    CreditCard.where(id: card_ids).first
  end
end
