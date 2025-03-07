package chat.simplex.app.views.newchat

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.icerock.moko.resources.compose.stringResource
import chat.simplex.app.R
import chat.simplex.app.views.helpers.AppBarTitle
import chat.simplex.app.views.onboarding.ReadableText
import chat.simplex.app.views.onboarding.ReadableTextWithLink
import chat.simplex.res.MR

@Composable
fun AddContactLearnMore() {
  Column(
    Modifier.verticalScroll(rememberScrollState()),
  ) {
    AppBarTitle(stringResource(MR.strings.one_time_link))
    ReadableText(MR.strings.scan_qr_to_connect_to_contact)
    ReadableText(MR.strings.if_you_cant_meet_in_person)
    ReadableTextWithLink(MR.strings.read_more_in_user_guide_with_link, "https://simplex.chat/docs/guide/readme.html#connect-to-friends")
  }
}
