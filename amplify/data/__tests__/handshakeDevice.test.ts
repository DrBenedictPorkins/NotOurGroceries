import { deviceState } from '../handshakeFunction/handler';

/**
 * This decides whether a phone gets thrown off the account, and it answers on
 * every launch. Getting it wrong in the "evict" direction is the expensive
 * direction: the app signs the person out of a household they still belong to,
 * mid-shop, with no way to tell them why.
 *
 * The case that matters most is the boring one — an account that predates device
 * registration has no `activeDeviceId` at all. Reading that absence as "some
 * other device holds this" would have evicted every existing user the moment
 * they upgraded. Every "cannot tell" answer here holds the device rather than
 * dropping it.
 */
describe('deviceState', () => {
  it('holds an account that has never registered a device', () => {
    // Nobody has claimed since this shipped. Upgrading must not sign them out.
    expect(deviceState({ id: 'u1' }, 'device-A')).toEqual({
      stillOurs: true,
      activeDeviceName: null,
    });
  });

  it('holds the device that is registered on the account', () => {
    const user = { id: 'u1', activeDeviceId: 'device-A', activeDeviceName: 'Not Fone' };
    expect(deviceState(user, 'device-A')).toEqual({
      stillOurs: true,
      activeDeviceName: null,
    });
  });

  it('evicts a device once a different one has claimed the account', () => {
    const user = { id: 'u1', activeDeviceId: 'device-B', activeDeviceName: 'iPhonePT' };
    expect(deviceState(user, 'device-A')).toEqual({
      stillOurs: false,
      activeDeviceName: 'iPhonePT',
    });
  });

  it('names the device that took over, so the message can say which one', () => {
    const user = { id: 'u1', activeDeviceId: 'device-B', activeDeviceName: 'iPhonePT' };
    expect(deviceState(user, 'device-A').activeDeviceName).toBe('iPhonePT');
  });

  it('evicts without a name when the claiming device never recorded one', () => {
    const user = { id: 'u1', activeDeviceId: 'device-B' };
    expect(deviceState(user, 'device-A')).toEqual({
      stillOurs: false,
      activeDeviceName: null,
    });
  });

  it('withholds the name of the holding device while the account is still ours', () => {
    // Nothing to tell the user about, and the device name is another phone's.
    const user = { id: 'u1', activeDeviceId: 'device-A', activeDeviceName: 'Not Fone' };
    expect(deviceState(user, 'device-A').activeDeviceName).toBeNull();
  });

  it('holds when the caller did not send a device id', () => {
    // An older client, or one that could not read the identifier. We cannot
    // tell whose device this is, so we do not take the account away from it.
    const user = { id: 'u1', activeDeviceId: 'device-B', activeDeviceName: 'iPhonePT' };
    expect(deviceState(user, undefined)).toEqual({ stillOurs: true, activeDeviceName: null });
    expect(deviceState(user, null)).toEqual({ stillOurs: true, activeDeviceName: null });
    expect(deviceState(user, '')).toEqual({ stillOurs: true, activeDeviceName: null });
  });

  it('holds when there is no user row to read at all', () => {
    // Onboarding: signed in, row not written yet. Not a device conflict.
    expect(deviceState(null, 'device-A')).toEqual({ stillOurs: true, activeDeviceName: null });
  });
});
