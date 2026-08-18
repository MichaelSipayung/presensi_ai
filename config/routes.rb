Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations'
  }
  
  root 'attendances#index'
  post '/attendances/check_in', to: 'attendances#create'
end