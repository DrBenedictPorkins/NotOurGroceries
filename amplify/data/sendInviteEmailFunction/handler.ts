import { DynamoDBClient, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';

const dynamoClient = new DynamoDBClient({});
const sesClient = new SESClient({});

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;
const SES_SOURCE_EMAIL = process.env.SES_SOURCE_EMAIL || 'noreply@example.com';

type Handler = Schema['sendInviteEmail']['functionHandler'];

/**
 * Get household details
 */
async function getHousehold(householdId: string): Promise<{ name: string; inviteCode: string; inviteCodeExpiresAt: string } | null> {
  const result = await dynamoClient.send(new GetItemCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    Key: marshall({ id: householdId }),
  }));

  if (result.Item) {
    const household = unmarshall(result.Item);
    return {
      name: household.name,
      inviteCode: household.inviteCode,
      inviteCodeExpiresAt: household.inviteCodeExpiresAt,
    };
  }

  return null;
}

/**
 * Check if user is a member of the household
 */
async function isUserMember(userId: string, householdId: string): Promise<boolean> {
  const result = await dynamoClient.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));

  if (result.Item) {
    const user = unmarshall(result.Item);
    return user.householdId === householdId;
  }

  return false;
}

/**
 * Send invite email via SES
 */
async function sendEmail(recipientEmail: string, senderName: string, householdName: string, inviteCode: string): Promise<void> {
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
  const expiresAtFormatted = expiresAt.toLocaleDateString('en-US', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });

  const htmlBody = `
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .code { font-size: 32px; font-weight: bold; letter-spacing: 4px; color: #00D4FF; background: #1a1a2e; padding: 20px; border-radius: 12px; text-align: center; margin: 20px 0; }
        .footer { font-size: 12px; color: #666; margin-top: 30px; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>You're invited to join a household!</h1>
        <p><strong>${senderName}</strong> has invited you to join the <strong>"${householdName}"</strong> household on NotOurGroceries.</p>

        <p>Use this invite code to join:</p>
        <div class="code">${inviteCode}</div>

        <p>This code expires on ${expiresAtFormatted}.</p>

        <p><strong>How to join:</strong></p>
        <ol>
          <li>Open the NotOurGroceries app</li>
          <li>Go to the Household tab</li>
          <li>Select "Join Existing"</li>
          <li>Enter the invite code above</li>
        </ol>

        <div class="footer">
          <p>If you didn't expect this invitation, you can safely ignore this email.</p>
          <p>NotOurGroceries - Shared shopping lists for families</p>
        </div>
      </div>
    </body>
    </html>
  `;

  const textBody = `
You're invited to join a household!

${senderName} has invited you to join the "${householdName}" household on NotOurGroceries.

Use this invite code to join: ${inviteCode}

This code expires on ${expiresAtFormatted}.

How to join:
1. Open the NotOurGroceries app
2. Go to the Household tab
3. Select "Join Existing"
4. Enter the invite code above

If you didn't expect this invitation, you can safely ignore this email.
`;

  await sesClient.send(new SendEmailCommand({
    Source: SES_SOURCE_EMAIL,
    Destination: {
      ToAddresses: [recipientEmail],
    },
    Message: {
      Subject: {
        Data: `${senderName} invited you to join "${householdName}" on NotOurGroceries`,
      },
      Body: {
        Html: { Data: htmlBody },
        Text: { Data: textBody },
      },
    },
  }));
}

export const handler: Handler = async (event) => {
  console.log('sendInviteEmail Lambda invoked');
  console.log('Event:', JSON.stringify(event, null, 2));

  try {
    const { householdId, recipientEmail, senderName } = event.arguments;

    // Get user identity
    const eventWithIdentity = event as typeof event & {
      identity?: {
        sub?: string;
        claims?: Record<string, unknown>;
      }
    };

    const identity = eventWithIdentity.identity;
    const userId = identity?.sub || (identity?.claims?.['sub'] as string);

    if (!userId) {
      throw new Error('User identity not found');
    }

    // Verify user is a member of this household
    const isMember = await isUserMember(userId, householdId);
    if (!isMember) {
      throw new Error('You are not a member of this household');
    }

    // Get household details
    const household = await getHousehold(householdId);
    if (!household) {
      throw new Error('Household not found');
    }

    // Check if invite code is expired - if so, return error suggesting regeneration
    const expiresAt = new Date(household.inviteCodeExpiresAt);
    if (expiresAt < new Date()) {
      return {
        success: false,
        message: 'Invite code has expired. Please regenerate a new code before sending invitations.',
      };
    }

    // Send the email
    try {
      await sendEmail(recipientEmail, senderName, household.name, household.inviteCode);
      console.log(`Invite email sent to ${recipientEmail}`);

      return {
        success: true,
        message: `Invitation sent to ${recipientEmail}`,
      };
    } catch (emailError) {
      console.error('Error sending email:', emailError);
      return {
        success: false,
        message: 'Failed to send email. Please try again or share the invite code manually.',
      };
    }
  } catch (error) {
    console.error('Error in sendInviteEmail:', error);
    throw error;
  }
};
