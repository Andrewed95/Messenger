from django.contrib import admin
from .models import User, EncryptedKey


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ['username', 'created_at', 'key_count']
    search_fields = ['username']
    readonly_fields = ['created_at']

    def key_count(self, obj):
        return obj.keys.count()
    key_count.short_description = 'Number of Keys'


@admin.register(EncryptedKey)
class EncryptedKeyAdmin(admin.ModelAdmin):
    list_display = ['user', 'created_at', 'payload_hash_short']
    list_filter = ['created_at']
    search_fields = ['user__username', 'payload_hash']
    readonly_fields = ['created_at', 'payload_hash']
    ordering = ['-created_at']

    # Show first 16 chars of hash for readability
    def payload_hash_short(self, obj):
        return obj.payload_hash[:16] + '...'
    payload_hash_short.short_description = 'Payload Hash'

    # Display encrypted payload (truncated)
    def get_readonly_fields(self, request, obj=None):
        if obj:  # Editing existing
            return self.readonly_fields + ('user', 'encrypted_payload')
        return self.readonly_fields
