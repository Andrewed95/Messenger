from django.urls import path
from .views import StoreKeyView

urlpatterns = [
    path('api/v1/store-key', StoreKeyView.as_view(), name='store_key'),
]
